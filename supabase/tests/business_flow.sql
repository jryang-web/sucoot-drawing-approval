-- SUCOOT V5.7 | 業務流程自動化測試（資料庫層）
-- 以真實的 authenticated 角色 + JWT claims（auth.uid()）執行 RPC，驗證權限與狀態轉換。
-- 整個測試在單一交易中執行，最後一定以 RAISE EXCEPTION 結束 → 全部回滾，不留下任何資料。
-- 結果以例外訊息回傳（JSON）。注意：request_no 序號會前進（序號不受回滾影響），屬正常現象。
-- 測試員工使用隨機 auth_user_id；為此在交易內暫時移除 employees.auth_user_id 的 FK（同樣回滾）。
-- 本測試不寫入 auth.users。

do $test$
declare
  -- 測試身分（auth uid）
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid();
  u5 uuid := gen_random_uuid(); u6 uuid := gen_random_uuid(); u7 uuid := gen_random_uuid(); u8 uuid := gen_random_uuid();
  e1 uuid; e2 uuid; e3 uuid; e4 uuid; e5 uuid; e6 uuid; e7 uuid; e8 uuid;
  d_mfg uuid; d_eng uuid; d_dwg uuid; d_adm uuid;
  r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; r6 uuid; r7 uuid; r8 uuid; r9 uuid;
  it2 uuid; ab uuid; v text; n int; res jsonb := '[]';
  items3 jsonb := '[{"drawing_no":"A-001","drawing_name":"底座","purpose":"組裝","needed_date":"2026-12-01"},
                    {"drawing_no":"A-002","drawing_name":"側板","purpose":"組裝","needed_date":"2026-12-01","is_urgent":true,"urgency_reason":"產線停線"},
                    {"drawing_no":"A-003","drawing_name":"蓋板","revision":"B","purpose":"組裝","needed_date":"2026-12-02"}]';
  item1 jsonb := '[{"drawing_no":"B-100","drawing_name":"支架","purpose":"試作","needed_date":"2026-12-05"}]';
begin
  -- ------------------------------------------------------------------ helpers
  create function pg_temp.run(p_uid uuid, p_sql text) returns text language plpgsql as $f$
  declare v text;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    begin
      execute p_sql into v;
      v := 'OK:' || coalesce(v, '');
    exception when others then
      v := sqlerrm;
    end;
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);
    return v;
  end $f$;

  create function pg_temp.chk(p_test text, p_actual text, p_expected text) returns jsonb language sql as $f$
    select jsonb_build_array(jsonb_build_object('test', p_test, 'expected', p_expected, 'actual', p_actual,
      'pass', case when p_expected = 'OK' then p_actual like 'OK:%' else p_actual like p_expected || '%' end))
  $f$;

  create function pg_temp.val(p_actual text) returns uuid language sql as $f$
    select case when p_actual like 'OK:%' then nullif(substr(p_actual, 4), '')::uuid end
  $f$;

  create function pg_temp.status(p_id uuid) returns text language sql as $f$
    select status::text from public.drawing_requests where id = p_id
  $f$;

  -- ------------------------------------------------------------------ fixtures（管理者在系統內建立的組織）
  alter table public.employees drop constraint employees_auth_user_id_fkey;
  insert into public.departments (code, name) values ('T_MFG', '測試製造部') returning id into d_mfg;
  insert into public.departments (code, name) values ('T_ENG', '測試工程部') returning id into d_eng;
  insert into public.departments (code, name) values ('T_DWG', '測試圖管部') returning id into d_dwg;
  insert into public.departments (code, name) values ('T_ADM', '測試管理部') returning id into d_adm;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST001', u1, '測試員工A', d_mfg, false) returning id into e1;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST002', u2, '測試員工B', d_mfg, false) returning id into e2;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST003', u3, '測試主管A', d_mfg, false) returning id into e3;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST004', u4, '測試圖管主管', d_dwg, false) returning id into e4;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST005', u5, '測試圖管人員', d_dwg, false) returning id into e5;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST006', u6, '測試系統管理員', d_adm, false) returning id into e6;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST007', u7, '測試主管B', d_eng, false) returning id into e7;
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password) values
    ('TEST008', u8, '測試圖管人員B', d_dwg, false) returning id into e8;
  insert into public.employee_roles (employee_id, role)
    select e, 'EMPLOYEE' from unnest(array[e1,e2,e3,e4,e5,e6,e7,e8]) e;
  insert into public.employee_roles (employee_id, role) values
    (e3, 'DEPT_MANAGER'), (e7, 'DEPT_MANAGER'), (e4, 'DRAWING_MANAGER'),
    (e5, 'DRAWING_STAFF'), (e8, 'DRAWING_STAFF'), (e6, 'SYS_ADMIN');
  -- 管理者設定：TEST003 管製造部；TEST007 管工程部＋圖管部＋管理部（Q5 由管理者自行設定）
  insert into public.manager_departments (manager_id, department_id) values
    (e3, d_mfg), (e7, d_eng), (e7, d_dwg), (e7, d_adm);

  -- ================================================================== 申請與第一層
  v := pg_temp.run(u1, format('select public.save_draft(null, %L, %L::jsonb)', '整案備註', items3));
  r1 := pg_temp.val(v);
  res := res || pg_temp.chk('S01 TEST001 建立草稿（3 筆圖號）', v, 'OK');
  res := res || pg_temp.chk('S01 TEST001 正式送出申請', pg_temp.run(u1, format('select public.submit_request(%L)', r1)), 'OK');
  res := res || pg_temp.chk('S01 送出後狀態 = PENDING_DEPT_REVIEW', 'OK:' || pg_temp.status(r1), 'OK:PENDING_DEPT_REVIEW');

  res := res || pg_temp.chk('X01 TEST002 看不到 TEST001 的案件（RLS）',
    pg_temp.run(u2, format('select count(*)::text from public.drawing_requests where id = %L', r1)), 'OK:0');
  res := res || pg_temp.chk('X02 TEST007 看不到製造部案件（RLS）',
    pg_temp.run(u7, format('select count(*)::text from public.v_requests where id = %L', r1)), 'OK:0');
  res := res || pg_temp.chk('X03 TEST002 不可修改他人申請',
    pg_temp.run(u2, format('select public.save_draft(%L, null, %L::jsonb)', r1, item1)), 'FORBIDDEN');
  res := res || pg_temp.chk('X04 前端直接 UPDATE 案件狀態被拒（無寫入權限）',
    pg_temp.run(u1, format('update public.drawing_requests set status = ''COMPLETED'' where id = %L returning id', r1)), 'permission denied');
  res := res || pg_temp.chk('X05 一般員工不可審核（TEST002 第一層）',
    pg_temp.run(u2, format('select public.review_level1(%L, ''APPROVE'')', r1)), 'FORBIDDEN');

  v := pg_temp.run(u2, format('select public.save_draft(null, null, %L::jsonb)', item1)); r2 := pg_temp.val(v);
  perform pg_temp.run(u2, format('select public.submit_request(%L)', r2));
  res := res || pg_temp.chk('S04 TEST007 審核製造部申請 → 拒絕',
    pg_temp.run(u7, format('select public.review_level1(%L, ''APPROVE'')', r2)), 'FORBIDDEN');

  res := res || pg_temp.chk('X06 版本衝突（過期 version）被拒',
    pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'', null, null, 999)', r1)), 'VERSION_CONFLICT');
  res := res || pg_temp.chk('X07 第一層調降急件未填原因 → 拒絕',
    pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'', null, ''[{"item_id":"%s","reason":""}]''::jsonb)', r1,
      (select id from public.drawing_request_items where request_id = r1 and line_no = 2))), 'REASON_REQUIRED');
  res := res || pg_temp.chk('S02 TEST003 核准 TEST001 申請（含調降急件）',
    pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'', null, ''[{"item_id":"%s","reason":"庫存足夠"}]''::jsonb)', r1,
      (select id from public.drawing_request_items where request_id = r1 and line_no = 2))), 'OK');
  res := res || pg_temp.chk('S02 急件已調降並記錄原因',
    'OK:' || (select (not is_urgent and downgrade_reason = '庫存足夠')::text from public.drawing_request_items where request_id = r1 and line_no = 2), 'OK:true');
  res := res || pg_temp.chk('X08 重複第一層審核 → 拒絕',
    pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'')', r1)), 'INVALID_STATUS');
  res := res || pg_temp.chk('S13 第一層核准後自行取消 → 拒絕',
    pg_temp.run(u1, format('select public.cancel_request(%L, ''不要了'')', r1)), 'INVALID_STATUS');

  -- TEST003 自行申請與審核
  v := pg_temp.run(u3, format('select public.save_draft(null, null, %L::jsonb)', item1)); r3 := pg_temp.val(v);
  perform pg_temp.run(u3, format('select public.submit_request(%L)', r3));
  res := res || pg_temp.chk('S03 TEST003 審核自己的申請（第一層）',
    pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'')', r3)), 'OK');

  -- ================================================================== 第二層
  res := res || pg_temp.chk('X09 部門主管不可執行第二層（TEST003）',
    pg_temp.run(u3, format('select public.review_level2(%L, ''APPROVE'')', r1)), 'FORBIDDEN');
  res := res || pg_temp.chk('S05 TEST004 第二層核准（TEST001 案）',
    pg_temp.run(u4, format('select public.review_level2(%L, ''APPROVE'')', r1)), 'OK');
  res := res || pg_temp.chk('S05 TEST004 第二層核准（TEST003 案）',
    pg_temp.run(u4, format('select public.review_level2(%L, ''APPROVE'')', r3)), 'OK');
  res := res || pg_temp.chk('X10 第二層不可跳過第一層（TEST002 案仍在第一層）',
    pg_temp.run(u4, format('select public.review_level2(%L, ''APPROVE'')', r2)), 'INVALID_STATUS');

  -- TEST004 自行申請：第一層由 TEST007（管轄圖管部）審，第二層 TEST004 自審
  v := pg_temp.run(u4, format('select public.save_draft(null, null, %L::jsonb)', item1)); r4 := pg_temp.val(v);
  perform pg_temp.run(u4, format('select public.submit_request(%L)', r4));
  res := res || pg_temp.chk('S06a 圖管主管自己的申請，第一層由部門主管 TEST007 核准',
    pg_temp.run(u7, format('select public.review_level1(%L, ''APPROVE'')', r4)), 'OK');
  res := res || pg_temp.chk('S06 TEST004 審核自己的申請（第二層，兩層不同人）',
    pg_temp.run(u4, format('select public.review_level2(%L, ''APPROVE'')', r4)), 'OK');

  -- 同一人兩層：管理者讓 TEST004 也成為圖管部的部門主管
  res := res || pg_temp.chk('X11 一般員工不可呼叫管理 RPC',
    pg_temp.run(u1, format('select public.admin_set_roles(%L, ''{DEPT_MANAGER}'')', e1)), 'FORBIDDEN');
  res := res || pg_temp.chk('X12 管理者授予 TEST004 部門主管角色',
    pg_temp.run(u6, format('select public.admin_set_roles(%L, ''{DRAWING_MANAGER,DEPT_MANAGER}'', ''測試'')', e4)), 'OK');
  res := res || pg_temp.chk('X12 管理者設定 TEST004 管轄圖管部',
    pg_temp.run(u6, format('select public.admin_set_manager_departments(%L, array[%L]::uuid[], ''測試'')', e4, d_dwg)), 'OK');
  v := pg_temp.run(u5, format('select public.save_draft(null, null, %L::jsonb)', item1)); r5 := pg_temp.val(v);
  perform pg_temp.run(u5, format('select public.submit_request(%L)', r5));
  res := res || pg_temp.chk('S07a TEST004 第一層核准 TEST005 申請',
    pg_temp.run(u4, format('select public.review_level1(%L, ''APPROVE'')', r5)), 'OK');
  res := res || pg_temp.chk('S07 同一人嘗試執行兩層審核 → 拒絕',
    pg_temp.run(u4, format('select public.review_level2(%L, ''APPROVE'')', r5)), 'SAME_REVIEWER');
  res := res || pg_temp.chk('X13 管理者不可移除自己的系統管理員角色',
    pg_temp.run(u6, format('select public.admin_set_roles(%L, ''{}'', ''測試'')', e6)), 'FORBIDDEN');

  -- ================================================================== 退回與重送
  v := pg_temp.run(u1, format('select public.save_draft(null, null, %L::jsonb)', item1)); r6 := pg_temp.val(v);
  perform pg_temp.run(u1, format('select public.submit_request(%L)', r6));
  res := res || pg_temp.chk('X14 退回未填意見 → 拒絕',
    pg_temp.run(u3, format('select public.review_level1(%L, ''RETURN'')', r6)), 'REASON_REQUIRED');
  res := res || pg_temp.chk('S08a TEST003 第一層退回',
    pg_temp.run(u3, format('select public.review_level1(%L, ''RETURN'', ''請補版次'')', r6)), 'OK');
  res := res || pg_temp.chk('S08b 申請人修改內容',
    pg_temp.run(u1, format('select public.save_draft(%L, null, %L::jsonb)', r6,
      '[{"drawing_no":"B-100","drawing_name":"支架","revision":"C","purpose":"試作","needed_date":"2026-12-05"}]')), 'OK');
  res := res || pg_temp.chk('S08 第一層退回後重新送出（有修改，不需說明）',
    pg_temp.run(u1, format('select public.submit_request(%L)', r6)), 'OK');
  res := res || pg_temp.chk('S08 回到第一層，輪次 = 2',
    'OK:' || (select status || '/' || round from public.drawing_requests where id = r6), 'OK:PENDING_DEPT_REVIEW/2');

  v := pg_temp.run(u1, format('select public.save_draft(null, null, %L::jsonb)', item1)); r7 := pg_temp.val(v);
  perform pg_temp.run(u1, format('select public.submit_request(%L)', r7));
  perform pg_temp.run(u3, format('select public.review_level1(%L, ''APPROVE'')', r7));
  res := res || pg_temp.chk('S09a TEST004 第二層退回',
    pg_temp.run(u4, format('select public.review_level2(%L, ''RETURN'', ''圖號有誤'')', r7)), 'OK');
  res := res || pg_temp.chk('S11 第二層退回未修改且無回覆說明 → 拒絕重送',
    pg_temp.run(u1, format('select public.submit_request(%L)', r7)), 'RESUBMIT_NOTE_REQUIRED');
  res := res || pg_temp.chk('S10 第二層退回未修改但有回覆說明 → 成功重送',
    pg_temp.run(u1, format('select public.submit_request(%L, null, ''圖號確認無誤，請再審'')', r7)), 'OK');
  res := res || pg_temp.chk('S09 第二層退回後重送 → 回到第一層',
    'OK:' || pg_temp.status(r7), 'OK:PENDING_DEPT_REVIEW');
  res := res || pg_temp.chk('S09 原核准紀錄保留但失效（R04）',
    'OK:' || (select count(*) filter (where not is_effective) || '/' || count(*) filter (where is_effective) from public.review_records where request_id = r7), 'OK:2/0');

  -- ================================================================== 取消
  v := pg_temp.run(u2, format('select public.save_draft(null, null, %L::jsonb)', item1)); r8 := pg_temp.val(v);
  perform pg_temp.run(u2, format('select public.submit_request(%L)', r8));
  res := res || pg_temp.chk('S12 第一層核准前自行取消 → 成功',
    pg_temp.run(u2, format('select public.cancel_request(%L, ''需求取消'')', r8)), 'OK');
  res := res || pg_temp.chk('X15 他人不可取消（TEST001 取消 TEST002 案）',
    pg_temp.run(u1, format('select public.cancel_request(%L, ''x'')', r2)), 'FORBIDDEN');

  -- ================================================================== 發行
  res := res || pg_temp.chk('S22 TEST006 跳過審核直接發行 → 拒絕（無圖管角色）',
    pg_temp.run(u6, format('select public.record_issue(%L)', r2)), 'FORBIDDEN');
  res := res || pg_temp.chk('S22b 圖管人員對未核准案件發行 → 拒絕',
    pg_temp.run(u5, format('select public.record_issue(%L)', r2)), 'INVALID_STATUS');
  res := res || pg_temp.chk('S15 TEST004 自行發行 → 拒絕',
    pg_temp.run(u4, format('select public.claim_issue(%L)', r1)), 'FORBIDDEN');
  res := res || pg_temp.chk('X16 未認領不可發行',
    pg_temp.run(u5, format('select public.record_issue(%L)', r1)), 'NOT_CLAIMED');
  res := res || pg_temp.chk('S14a TEST005 整案認領',
    pg_temp.run(u5, format('select public.claim_issue(%L)', r1)), 'OK');
  res := res || pg_temp.chk('X17 重複認領 → 拒絕',
    pg_temp.run(u8, format('select public.claim_issue(%L)', r1)), 'ALREADY_CLAIMED');
  res := res || pg_temp.chk('S16 管理員解除認領並重新指派給 TEST008',
    pg_temp.run(u6, format('select public.admin_release_claim(%L, ''TEST005 請假'', %L)', r1, e8)), 'OK');
  res := res || pg_temp.chk('S16 認領紀錄保留原認領人、接手人、原因',
    'OK:' || (select count(*) from public.issue_claims where request_id = r1 and staff_id = e5 and released_at is not null
              and reassigned_to = e8 and release_reason = 'TEST005 請假')
          || '/' || (select count(*) from public.issue_claims where request_id = r1 and staff_id = e8 and released_at is null), 'OK:1/1');
  res := res || pg_temp.chk('S16 解除認領寫入稽核紀錄',
    'OK:' || (select count(*) from public.admin_audit_logs where action = 'CLAIM_REASSIGN' and target_id = r1::text), 'OK:1');
  res := res || pg_temp.chk('X18 原認領人已解除，不可發行',
    pg_temp.run(u5, format('select public.record_issue(%L)', r1)), 'NOT_CLAIMED');
  res := res || pg_temp.chk('S14 圖管人員登記發行完成',
    pg_temp.run(u8, format('select public.record_issue(%L, ''LINE 群組 11/16 10:30'')', r1)), 'OK');
  res := res || pg_temp.chk('S14 狀態 = PENDING_RECEIPT，期限 = 發行日 + 3 工作日',
    'OK:' || (select status || '/' || (receipt_due_date = app.add_business_days(app.today_tpe(), 3))::text from public.drawing_requests where id = r1),
    'OK:PENDING_RECEIPT/true');

  -- ================================================================== 簽收與異常
  res := res || pg_temp.chk('S21 TEST005 代替申請人簽收 → 拒絕',
    pg_temp.run(u5, format('select public.confirm_receipt(%L)', r1)), 'FORBIDDEN');
  it2 := (select id from public.drawing_request_items where request_id = r1 and line_no = 2);
  res := res || pg_temp.chk('S17a 申請人回報第 2 筆圖號異常',
    pg_temp.run(u1, format('select public.report_abnormal(%L, ''[{"item_id":"%s","reason":"檔案模糊"}]''::jsonb)', r1, it2)), 'OK');
  res := res || pg_temp.chk('S17a 狀態 = ISSUE_ABNORMAL', 'OK:' || pg_temp.status(r1), 'OK:ISSUE_ABNORMAL');
  res := res || pg_temp.chk('S18 異常尚未確認就結案 → 拒絕',
    pg_temp.run(u1, format('select public.confirm_receipt(%L)', r1)), 'INVALID_STATUS');
  ab := (select id from public.item_abnormal_reports where item_id = it2);
  res := res || pg_temp.chk('X19 補發前不可確認',
    pg_temp.run(u1, format('select public.confirm_reissued_item(%L)', ab)), 'INVALID_STATUS');
  res := res || pg_temp.chk('S17b 圖管人員只補發異常圖號',
    pg_temp.run(u5, format('select public.reissue_item(%L, ''重新上傳'')', ab)), 'OK');
  res := res || pg_temp.chk('S17 補發紀錄只有異常的第 2 筆（正常圖號不重發）',
    'OK:' || (select string_agg(i.line_no::text, ',') from public.issue_records x join public.drawing_request_items i on i.id = x.item_id
              where x.request_id = r1 and x.kind = 'REISSUE'), 'OK:2');
  res := res || pg_temp.chk('S18b 補發後仍未確認 → 結案拒絕',
    pg_temp.run(u1, format('select public.confirm_receipt(%L)', r1)), 'INVALID_STATUS');
  res := res || pg_temp.chk('X20 圖管人員不可代為確認補發',
    pg_temp.run(u5, format('select public.confirm_reissued_item(%L)', ab)), 'FORBIDDEN');
  res := res || pg_temp.chk('S17c 申請人確認補發圖號 → 回到待簽收',
    pg_temp.run(u1, format('select public.confirm_reissued_item(%L)', ab)), 'OK');
  res := res || pg_temp.chk('S17c 狀態 = PENDING_RECEIPT', 'OK:' || pg_temp.status(r1), 'OK:PENDING_RECEIPT');
  res := res || pg_temp.chk('S17d 整案簽收 → COMPLETED',
    pg_temp.run(u1, format('select public.confirm_receipt(%L)', r1)), 'OK');
  res := res || pg_temp.chk('X21 重複結案 → 拒絕',
    pg_temp.run(u1, format('select public.confirm_receipt(%L)', r1)), 'INVALID_STATUS');

  -- ================================================================== 逾期（R05）
  res := res || pg_temp.chk('S19a 週一發行 → 期限週四', 'OK:' || public.calc_receipt_due('2026-11-16')::text, 'OK:2026-11-19');
  res := res || pg_temp.chk('S19b 週五發行 → 期限下週三', 'OK:' || public.calc_receipt_due('2026-11-20')::text, 'OK:2026-11-25');
  res := res || pg_temp.chk('S19c 期限當日未逾期', 'OK:' || public.calc_is_overdue('2026-11-19', 'PENDING_RECEIPT', '2026-11-19')::text, 'OK:false');
  res := res || pg_temp.chk('S19d 期限隔日標記逾期', 'OK:' || public.calc_is_overdue('2026-11-19', 'PENDING_RECEIPT', '2026-11-20')::text, 'OK:true');
  res := res || pg_temp.chk('S19e 已完成不標記逾期', 'OK:' || public.calc_is_overdue('2026-11-19', 'COMPLETED', '2026-12-31')::text, 'OK:false');
  -- r3 實際發行後把期限改成過去，確認 view 標記逾期但不自動簽收／結案
  perform pg_temp.run(u5, format('select public.claim_issue(%L)', r3));
  perform pg_temp.run(u5, format('select public.record_issue(%L)', r3));
  update public.drawing_requests set receipt_due_date = app.today_tpe() - 10 where id = r3;
  res := res || pg_temp.chk('S19 三個工作日未簽收 → 標記逾期（不自動結案）',
    pg_temp.run(u3, format('select is_receipt_overdue::text || ''/'' || status from public.v_requests where id = %L', r3)), 'OK:true/PENDING_RECEIPT');

  -- ================================================================== 移交（E06）
  res := res || pg_temp.chk('X22 非管理者不可移交',
    pg_temp.run(u3, format('select public.admin_transfer_owner(%L, %L, ''x'')', r3, e2)), 'FORBIDDEN');
  res := res || pg_temp.chk('S20 管理員移交簽收負責人給 TEST002',
    pg_temp.run(u6, format('select public.admin_transfer_owner(%L, %L, ''TEST003 調職'')', r3, e2)), 'OK');
  res := res || pg_temp.chk('S20 原申請人保留、負責人變更、移交紀錄存在',
    'OK:' || (select (applicant_id = e3 and owner_id = e2)::text from public.drawing_requests where id = r3)
          || '/' || (select count(*) from public.ownership_transfers where request_id = r3 and from_owner_id = e3 and to_owner_id = e2),
    'OK:true/1');
  res := res || pg_temp.chk('S20b 原申請人移交後不可簽收',
    pg_temp.run(u3, format('select public.confirm_receipt(%L)', r3)), 'FORBIDDEN');
  res := res || pg_temp.chk('S20c 原申請人仍可查看案件（唯讀）',
    pg_temp.run(u3, format('select count(*)::text from public.drawing_requests where id = %L', r3)), 'OK:1');
  res := res || pg_temp.chk('S20d 新負責人以自己帳號簽收',
    pg_temp.run(u2, format('select public.confirm_receipt(%L)', r3)), 'OK');

  -- ================================================================== 代理（E03）
  res := res || pg_temp.chk('X23 代理人須具相同角色（TEST001 不可代理第一層）',
    pg_temp.run(u6, format('select public.admin_create_delegation(%L, %L, 1::smallint, %L, %L, ''請假'')', e3, e1, app.today_tpe(), app.today_tpe() + 3)), 'INVALID_DELEGATE');
  res := res || pg_temp.chk('X24 代理期間超過 30 天 → 拒絕',
    pg_temp.run(u6, format('select public.admin_create_delegation(%L, %L, 1::smallint, %L, %L, ''請假'')', e3, e7, app.today_tpe(), app.today_tpe() + 40)), 'INVALID_PERIOD');
  res := res || pg_temp.chk('E03 管理員指定 TEST007 代理 TEST003 第一層',
    pg_temp.run(u6, format('select public.admin_create_delegation(%L, %L, 1::smallint, %L, %L, ''TEST003 請假'')', e3, e7, app.today_tpe(), app.today_tpe() + 3)), 'OK');
  res := res || pg_temp.chk('E03 代理人審核製造部案件 → 成功並記錄代理',
    pg_temp.run(u7, format('select public.review_level1(%L, ''APPROVE'')', r2)), 'OK');
  res := res || pg_temp.chk('E03 審核紀錄含實際審核者與被代理人',
    'OK:' || (select (reviewer_id = e7 and on_behalf_of_id = e3 and delegation_id is not null)::text from public.review_records where request_id = r2 and level = 1), 'OK:true');

  -- ================================================================== 帳號停用與首次改密碼
  perform public.svc_set_active(u6, e2, false, '離職');
  res := res || pg_temp.chk('S23 停用帳號（既有 session）操作業務 → 拒絕',
    pg_temp.run(u2, format('select public.save_draft(null, null, %L::jsonb)', item1)), 'ACCOUNT_INACTIVE');
  res := res || pg_temp.chk('S23b 停用帳號查詢資料 → 0 筆',
    pg_temp.run(u2, 'select count(*)::text from public.v_requests'), 'OK:0');
  res := res || pg_temp.chk('S23c 停用帳號呼叫 me() → 拒絕', pg_temp.run(u2, 'select public.me()::text'), 'ACCOUNT_INACTIVE');
  begin
    perform public.svc_set_active(u6, e6, false, 'x'); v := 'OK:';
  exception when others then v := sqlerrm; end;
  res := res || pg_temp.chk('X25 管理者不可停用自己', v, 'FORBIDDEN');
  begin
    perform public.svc_set_active(u6, e2, true, '測試'); v := 'OK:';
  exception when others then v := sqlerrm; end;
  update public.employees set must_change_password = true where id = e8;
  res := res || pg_temp.chk('X26 尚未修改初始密碼 → 業務操作拒絕',
    pg_temp.run(u8, format('select public.save_draft(null, null, %L::jsonb)', item1)), 'PASSWORD_CHANGE_REQUIRED');
  begin
    delete from public.request_status_history where request_id = r1; v := 'OK:';
  exception when others then v := sqlerrm; end;
  res := res || pg_temp.chk('X27 刪除狀態歷史被 trigger 拒絕', v, 'IMMUTABLE');

  raise exception 'TEST_RESULT %', jsonb_build_object('fatal', null,
    'total', jsonb_array_length(res),
    'passed', (select count(*) from jsonb_array_elements(res) x where (x->>'pass')::boolean),
    'failures', coalesce((select jsonb_agg(x) from jsonb_array_elements(res) x where not (x->>'pass')::boolean), '[]')));
exception when others then
  if sqlerrm like 'TEST_RESULT%' then raise; end if;
  raise exception 'TEST_RESULT %', jsonb_build_object('fatal', sqlerrm, 'results', res);
end $test$;
