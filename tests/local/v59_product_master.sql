-- SUCOOT V5.9｜產品主檔與 Excel 同步：後端隔離測試（只可在隔離本機資料庫執行）
-- 執行：psql -v ON_ERROR_STOP=1 -f tests/local/v59_product_master.sql
-- 每一步以指定 TEST 帳號的 session、authenticated 角色執行；整個測試在單一交易中，最後 rollback，不留下資料。
\set ON_ERROR_STOP on
begin;

-- 以指定員工身分執行 SQL，回傳 'OK:<結果>' 或錯誤訊息
create function pg_temp.run(who text, sql text) returns text language plpgsql as $f$
declare v text; claims text;
begin
  if who is not null then
    select jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text into strict claims
      from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
     where e.employee_no = who;
  end if;
  perform set_config('request.jwt.claims', coalesce(claims, ''), true);
  perform set_config('role', case when who is null then 'anon' else 'authenticated' end, true);
  begin
    execute sql into v; v := 'OK:' || coalesce(v, '');
  exception when others then v := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $f$;

-- 匯入預覽（管理員身分）→ 回傳 jsonb；rows 為 [[code,name,spec], ...]
create function pg_temp.preview(who text, rows jsonb, header jsonb default '["產品代碼","品名","規格"]') returns jsonb language plpgsql as $f$
declare r text;
begin
  r := pg_temp.run(who, format('select public.admin_product_import_preview(%L, null, %L::jsonb, %L::jsonb)::text', 'test.xlsx', header,
        (select coalesce(jsonb_agg(jsonb_build_object('row', n + 1, 'code', x->>0, 'name', x->>1, 'spec', x->>2) order by n), '[]')
           from jsonb_array_elements(rows) with ordinality t(x, n))));
  if r not like 'OK:%' then raise exception 'preview failed: %', r; end if;
  return substr(r, 4)::jsonb;
end $f$;

create function pg_temp.commit(who text, batch jsonb, confirm boolean default false) returns text language sql as $f$
  select pg_temp.run(who, format('select public.admin_product_import_commit(%L, %L)::text', batch->>'batch_id', confirm))
$f$;

-- 員工送件：與前端相同，經由冪等操作機制 prepare_operation → execute_operation（回傳 {ok, id} 或 {ok:false, error}）
create function pg_temp.apply(who text, products jsonb) returns jsonb language plpgsql as $f$
declare k uuid := gen_random_uuid(); r text;
begin
  r := pg_temp.run(who, format('select public.prepare_operation(%L, ''write_r8_application'', %L::jsonb)::text', k,
         jsonb_build_object('p_purpose', '施工使用', 'p_urgent', false, 'p_reason', null, 'p_note', null, 'p_products', products, 'p_submit', true, 'p_id', null, 'p_version', null)));
  if r not like 'OK:%' then return jsonb_build_object('ok', false, 'error', r); end if;
  r := pg_temp.run(who, format('select public.execute_operation(%L)::text', k));
  if r not like 'OK:%' then return jsonb_build_object('ok', false, 'error', r); end if;
  return substr(r, 4)::jsonb;
end $f$;

create function pg_temp.search(who text, q text, lim int default 20) returns jsonb language plpgsql as $f$
declare r text := pg_temp.run(who, format('select public.search_products(%L, %s)::text', q, lim));
begin
  if r not like 'OK:%' then raise exception 'search failed: %', r; end if;
  return substr(r, 4)::jsonb;
end $f$;

create function pg_temp.codes(j jsonb) returns text language sql as $f$
  select coalesce(string_agg(x->>'code', ',' order by n), '') from jsonb_array_elements(j->'items') with ordinality t(x, n)
$f$;

create temp table t_result (n serial, name text, pass boolean, detail text);
create function pg_temp.ok(name text, pass boolean, detail text default null) returns void language sql as $f$
  insert into t_result (name, pass, detail) values (name, coalesce(pass, false), detail)
$f$;

do $test$
declare p jsonb; p2 jsonb; r text; v0 bigint; req uuid; c int;
begin
  -- 從空的產品主檔開始（僅限此交易）
  delete from public.product_import_rows; delete from public.product_import_batches; delete from public.products;
  update public.product_master_state set version = 0;

  -- ========== 權限：一般員工不得修改主檔
  perform pg_temp.ok('P1 一般員工不可預覽匯入',
    pg_temp.run('TEST001', 'select public.admin_product_import_preview(''x'', null, ''["產品代碼","品名","規格"]'', ''[]'')::text') like 'FORBIDDEN%');
  perform pg_temp.ok('P2 一般員工不可執行同步',
    pg_temp.run('TEST001', format('select public.admin_product_import_commit(%L)::text', gen_random_uuid())) like 'FORBIDDEN%');
  perform pg_temp.ok('P3 一般員工不可讀取管理統計', pg_temp.run('TEST001', 'select public.admin_product_master_summary()::text') like 'FORBIDDEN%');
  perform pg_temp.ok('P4 一般員工不可直接寫入產品表',
    pg_temp.run('TEST001', 'insert into public.products(code,name) values (''HACK'',''x'') returning code') like 'permission denied%');
  perform pg_temp.ok('P5 一般員工不可直接讀取產品表（只能透過搜尋 RPC）',
    pg_temp.run('TEST001', 'select count(*)::text from public.products') like 'permission denied%');
  perform pg_temp.ok('P6 未登入不可搜尋', pg_temp.run(null, 'select public.search_products(''a'')::text') like 'permission denied%');
  perform pg_temp.ok('P7 管理員也不可直接寫入產品表（只能經由匯入）',
    pg_temp.run('TEST006', 'update public.products set name = ''x'' returning code') like 'permission denied%');

  -- ========== 首次匯入（含大小寫不同、×、" 、前導零、前後空白）
  p := pg_temp.preview('TEST006', '[["P-001","螺栓","M8"],["P-002","螺帽","M8"],["P-003","墊片",""],["P-004","槽鋼","藍漆"],
    ["P-005","槽鋼","灰漆"],["AB-1","踏板","含舌片"],["ab-1","踏板","切角"],["GB-55×2-B","槽鋼(鉆孔)","藍漆"],
    ["H7-CO5802\"-5","連接器","紅丹漆"],["00123","前導零產品","  白鐵  "],["  P-SPACE  ","  前後空白  "," 黑 "]]');
  perform pg_temp.ok('I1 首次預覽：11 筆全部新增、無錯誤', (p->>'added')::int = 11 and (p->>'error_count')::int = 0 and (p->>'can_commit')::boolean, p::text);
  perform pg_temp.ok('I2 預覽提醒大小寫不同編碼 AB-1／ab-1', p->'warnings' @> '[{"codes":["AB-1","ab-1"]}]', p->>'warnings');
  perform pg_temp.ok('I3 預覽階段不修改主檔', (select count(*) from public.products) = 0);
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('I4 首次同步成功', r like 'OK:%', r);
  perform pg_temp.ok('I5 前導零保留', exists (select 1 from public.products where code = '00123'));
  perform pg_temp.ok('I6 只清除前後空白', exists (select 1 from public.products where code = 'P-SPACE' and name = '前後空白' and spec = '黑'));
  perform pg_temp.ok('I7 大小寫不同視為不同產品', (select count(*) from public.products where lower(code) = 'ab-1') = 2);
  perform pg_temp.ok('I8 主檔版本 +1', (select version from public.product_master_state) = 1);
  perform pg_temp.ok('I9 同步寫入稽核紀錄（操作者、數量）', exists (select 1 from public.admin_audit_logs a join public.employees e on e.id = a.actor_id
    where a.action = 'PRODUCT_IMPORT_COMMIT' and e.employee_no = 'TEST006' and (a.after->>'added')::int = 11));
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('I10 同一批次不可重複同步', r like 'ALREADY_COMMITTED%', r);

  -- ========== 搜尋
  perform pg_temp.ok('S1 依編碼搜尋', pg_temp.codes(pg_temp.search('TEST001', 'P-00')) = 'P-001,P-002,P-003,P-004,P-005');
  perform pg_temp.ok('S2 依品名搜尋（同名不同規格皆列出）', pg_temp.codes(pg_temp.search('TEST001', '槽鋼')) like '%P-004%P-005%');
  perform pg_temp.ok('S3 依規格搜尋', pg_temp.codes(pg_temp.search('TEST001', '灰漆')) = 'P-005');
  perform pg_temp.ok('S4 多關鍵字（全部符合）', pg_temp.codes(pg_temp.search('TEST001', '槽鋼 藍漆')) = 'GB-55×2-B,P-004');
  perform pg_temp.ok('S5 編碼完全相同（含大小寫）排第一', pg_temp.codes(pg_temp.search('TEST001', 'ab-1')) = 'ab-1,AB-1');
  perform pg_temp.ok('S6 含 × 與 " 的編碼可搜尋', pg_temp.codes(pg_temp.search('TEST001', '55×2')) = 'GB-55×2-B'
    and pg_temp.codes(pg_temp.search('TEST001', 'CO5802"')) = 'H7-CO5802"-5');
  perform pg_temp.ok('S7 全形輸入可搜尋', pg_temp.codes(pg_temp.search('TEST001', 'Ｐ－００１')) = 'P-001');
  perform pg_temp.ok('S8 萬用字元不生效', pg_temp.codes(pg_temp.search('TEST001', '%')) = '' and pg_temp.codes(pg_temp.search('TEST001', '_')) = '');
  p2 := pg_temp.search('TEST001', 'P-', 2);
  perform pg_temp.ok('S9 分頁（每頁上限＋還有更多）', jsonb_array_length(p2->'items') = 2 and (p2->>'has_more')::boolean);
  perform pg_temp.ok('S10 空白查詢不回傳資料', pg_temp.codes(pg_temp.search('TEST001', '   ')) = '');

  -- ========== 歷史案件：先用主檔產品送出案件，之後主檔更新不得改寫
  p2 := pg_temp.apply('TEST001', '[{"code":"P-002","name":"螺帽 / M8","remark":""},{"code":"GB-55×2-B","name":"槽鋼(鉆孔) / 藍漆","remark":""}]');
  perform pg_temp.ok('H1 員工可用含 × 的主檔編碼送出案件（V5.8 相容修正）', (p2->>'ok')::boolean, p2::text);
  req := (p2->>'id')::uuid;
  perform pg_temp.ok('H1b 案件進入第一層待審（V5.8 流程不變）', (select status::text from public.drawing_requests where id = req) = 'PENDING_DEPT_REVIEW');
  p2 := pg_temp.apply('TEST001', '[{"code":"NOT×MASTER","name":"x","remark":""}]');
  perform pg_temp.ok('H2 手動輸入且不在主檔的 × 編碼仍被拒（V5.8 規則不變）', p2->>'error' like 'INVALID_INPUT%', p2::text);
  p2 := pg_temp.apply('TEST001', '[{"code":"MANUAL-9","name":"手動","remark":""}]');
  perform pg_temp.ok('H3 手動輸入合規編碼照常可用', (p2->>'ok')::boolean, p2::text);
  p2 := pg_temp.apply('TEST001', '[{"code":"P-001","name":"a","remark":""},{"code":"P-001","name":"b","remark":""}]');
  perform pg_temp.ok('H4 同案重複編碼仍被拒', p2->>'error' like 'INVALID_INPUT%', p2::text);
  perform pg_temp.ok('H6 一般員工不可直接呼叫 write_r8_application（V5.8 授權不變）',
    pg_temp.run('TEST001', 'select public.write_r8_application(''a'',false,null,null,''[]'',false,null,null)::text') like 'permission denied%');

  -- ========== 第二次匯入：不變、更新、新增、停用（且超過 10% → 高風險）
  p := pg_temp.preview('TEST006', '[["P-001","螺栓","M8"],["P-002","螺帽（新）","M8"],["P-004","槽鋼","藍漆 2000mm"],["P-005","槽鋼","灰漆"],
    ["AB-1","踏板","含舌片"],["ab-1","踏板","切角"],["GB-55×2-B","槽鋼(鉆孔)","藍漆"],["H7-CO5802\"-5","連接器","紅丹漆"],
    ["00123","前導零產品","白鐵"],["P-SPACE","前後空白","黑"],["P-006","新產品","新規格"]]');
  perform pg_temp.ok('U1 預覽差異：新增1 更新2 不變8 停用1', (p->>'added', p->>'updated', p->>'unchanged', p->>'deactivated', p->>'reactivated')
    = ('1', '2', '8', '1', '0'), p::text);
  perform pg_temp.ok('U2 停用 1/11（9.1%）未達 10%，非高風險', not (p->>'high_risk')::boolean);
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('U3 同步成功', r like 'OK:%', r);
  perform pg_temp.ok('U4 未列於 Excel 的產品改為停用、不刪除', exists (select 1 from public.products where code = 'P-003' and not is_active and deactivated_at is not null));
  perform pg_temp.ok('U5 停用產品不出現在一般搜尋', pg_temp.codes(pg_temp.search('TEST001', '墊片')) = '');
  perform pg_temp.ok('U6 更新後的品名可搜尋', pg_temp.codes(pg_temp.search('TEST001', '螺帽（新）')) = 'P-002');
  perform pg_temp.ok('H5 已送出案件的產品資料不被主檔更新覆蓋',
    (select drawing_name from public.drawing_request_items where request_id = req and drawing_no = 'P-002') = '螺帽 / M8');

  -- ========== 重新啟用
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array(code, name, spec)) from public.products where is_active) || '[["P-003","墊片（新）",""]]');
  perform pg_temp.ok('R1 預覽：重新啟用 1、停用 0', (p->>'reactivated', p->>'deactivated', p->>'added') = ('1', '0', '0'), p::text);
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('R2 重新啟用並套用最新品名', r like 'OK:%' and exists (select 1 from public.products where code = 'P-003' and is_active and name = '墊片（新）'), r);
  perform pg_temp.ok('R3 重新啟用的產品可再搜尋', pg_temp.codes(pg_temp.search('TEST001', '墊片')) = 'P-003');

  -- ========== 大量停用警告（不完整 Excel）
  p := pg_temp.preview('TEST006', '[["P-001","螺栓","M8"],["P-002","螺帽（新）","M8"]]');
  perform pg_temp.ok('W1 預計停用 10/12 > 10% → 高風險', (p->>'high_risk')::boolean and (p->>'deactivated')::int = 10, p::text);
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('W2 高風險未額外確認 → 拒絕同步', r like 'HIGH_RISK_CONFIRM_REQUIRED%', r);
  perform pg_temp.ok('W3 被拒絕後主檔未變動', (select count(*) from public.products where is_active) = 12);
  -- 剛好 10%：12 筆停用 1 筆 = 8.3%（不警告）；另驗證邊界：10 筆中停用 1 筆 = 10%（不超過，不警告）
  delete from public.product_import_rows; delete from public.product_import_batches; delete from public.products; update public.product_master_state set version = 0;
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array('B-' || i, '品' || i, '')) from generate_series(1, 10) i));
  perform pg_temp.commit('TEST006', p);
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array('B-' || i, '品' || i, '')) from generate_series(1, 9) i));
  perform pg_temp.ok('W4 停用剛好 10%（1/10）不屬高風險', not (p->>'high_risk')::boolean and (p->>'deactivated')::int = 1, p::text);
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array('B-' || i, '品' || i, '')) from generate_series(1, 8) i));
  perform pg_temp.ok('W5 停用 20%（2/10）屬高風險', (p->>'high_risk')::boolean);
  r := pg_temp.commit('TEST006', p, true);
  perform pg_temp.ok('W6 額外確認後才可同步，並記錄已確認', r like 'OK:%' and exists (select 1 from public.product_import_batches where id = (p->>'batch_id')::uuid and high_risk_confirmed), r);

  -- ========== 異常 Excel：一律不得同步
  p := pg_temp.preview('TEST006', '[]');
  perform pg_temp.ok('E1 空白檔案 → 錯誤、不可同步', not (p->>'can_commit')::boolean and p->>'status' = 'REJECTED' and p->'errors' @> '[{"message":"檔案沒有任何產品資料"}]', p::text);
  perform pg_temp.ok('E2 有錯誤的批次被拒絕同步', pg_temp.commit('TEST006', p) like 'INVALID_BATCH%');
  p := pg_temp.preview('TEST006', '[["X-1","品名","規格"]]', '["產品代碼","品名"]');
  perform pg_temp.ok('E3 缺少必要欄位「規格」', not (p->>'can_commit')::boolean and p::text like '%缺少必要欄位：規格%', p->>'errors');
  p := pg_temp.preview('TEST006', '[["D-1","甲",""],["D-2","乙",""],["D-1","丙",""]]');
  perform pg_temp.ok('E4 重複產品代碼（標示兩列）', (p->>'error_count')::int = 2 and p::text like '%產品代碼重複%', p->>'errors');
  p := pg_temp.preview('TEST006', '[["","無編碼",""],["OK-1","",""],["HAS SPACE","x",""],["ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456","太長",""],["OK-2","正常",""]]');
  perform pg_temp.ok('E5 空編碼、空品名、編碼含空白、超過 30 字 → 4 個錯誤', (p->>'error_count')::int = 4 and not (p->>'can_commit')::boolean, p->>'errors');
  perform pg_temp.ok('E6 錯誤批次不修改主檔', (select count(*) from public.products where is_active) = 8);

  -- ========== 預覽後主檔被其他匯入修改 → 拒絕並要求重新預覽
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array(code, name, spec)) from public.products where is_active));
  p2 := pg_temp.preview('TEST008', (select jsonb_agg(jsonb_build_array(code, name, spec)) from public.products where is_active) || '[["C-1","另一位管理員新增",""]]');
  perform pg_temp.ok('C1 管理員 B 先同步成功', pg_temp.commit('TEST008', p2) like 'OK:%');
  r := pg_temp.commit('TEST006', p);
  perform pg_temp.ok('C2 管理員 A 的舊預覽被拒（STALE_PREVIEW）', r like 'STALE_PREVIEW%', r);
  perform pg_temp.ok('C3 不可確認他人預覽的批次', pg_temp.commit('TEST006', p2) like 'ALREADY_COMMITTED%'
    and pg_temp.commit('TEST006', pg_temp.preview('TEST008', '[["Z-1","z",""]]')) like 'FORBIDDEN%');

  -- ========== 交易失敗 → 全批回滾
  v0 := (select version from public.product_master_state);
  p := pg_temp.preview('TEST006', (select jsonb_agg(jsonb_build_array(code, name || '改', spec)) from public.products where is_active) || '[["NEW-ROLLBACK","新","" ]]');
  create function pg_temp.boom() returns trigger language plpgsql as $f$ begin if new.code = 'B-5' then raise exception 'SIMULATED_FAILURE'; end if; return new; end $f$;
  create trigger t_boom before update on public.products for each row execute function pg_temp.boom();
  r := pg_temp.commit('TEST006', p);
  drop trigger t_boom on public.products;
  perform pg_temp.ok('X1 中途失敗回傳錯誤', r like 'SIMULATED_FAILURE%', r);
  perform pg_temp.ok('X2 全批回滾：沒有新增、沒有更新、版本不變',
    not exists (select 1 from public.products where code = 'NEW-ROLLBACK') and not exists (select 1 from public.products where name like '%改')
    and (select version from public.product_master_state) = v0);
  perform pg_temp.ok('X3 批次仍為未同步狀態，可修正後重試', pg_temp.commit('TEST006', p) like 'OK:%');

  -- ========== 稽核
  select count(*) into c from public.admin_audit_logs where action in ('PRODUCT_IMPORT_PREVIEW', 'PRODUCT_IMPORT_COMMIT');
  perform pg_temp.ok('A1 每次預覽與同步皆有稽核紀錄', c >= 15, c::text);
end $test$;

select n, case when pass then 'PASS' else 'FAIL' end as result, name, case when pass then null else left(detail, 300) end as detail from t_result order by n;
select count(*) filter (where pass) as passed, count(*) as total from t_result;
do $$ begin if exists (select 1 from t_result where not pass) then raise exception 'V5.9 product master tests failed'; end if; end $$;
rollback;
