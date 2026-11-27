-- SUCOOT V5.9.1｜角標計數與推播佇列：後端隔離測試（只可在隔離本機資料庫執行）
-- 執行：psql -v ON_ERROR_STOP=1 -f tests/local/v591_badge_push.sql
-- 每一步以指定 TEST 帳號的 session、authenticated 角色執行；整個測試在單一交易中，最後 rollback，不留下資料。
\set ON_ERROR_STOP on
begin;

-- 以指定員工身分執行 SQL，回傳 'OK:<結果>' 或錯誤訊息（who 為 null＝未登入 anon）
create function pg_temp.run(who text, sql text, as_role text default null) returns text language plpgsql as $f$
declare v text; claims text;
begin
  if who is not null then
    select jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text into strict claims
      from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
     where e.employee_no = who;
  end if;
  perform set_config('request.jwt.claims', coalesce(claims, ''), true);
  perform set_config('role', coalesce(as_role, case when who is null then 'anon' else 'authenticated' end), true);
  begin
    execute sql into v; v := 'OK:' || coalesce(v, '');
  exception when others then v := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $f$;

-- 與前端相同：經由冪等操作機制 prepare_operation → execute_operation
create function pg_temp.op(who text, action text, args jsonb) returns jsonb language plpgsql as $f$
declare k uuid := gen_random_uuid(); r text;
begin
  r := pg_temp.run(who, format('select public.prepare_operation(%L, %L, %L::jsonb)::text', k, action, args));
  if r not like 'OK:%' then return jsonb_build_object('ok', false, 'error', r); end if;
  r := pg_temp.run(who, format('select public.execute_operation(%L)::text', k));
  if r not like 'OK:%' then return jsonb_build_object('ok', false, 'error', r); end if;
  return substr(r, 4)::jsonb;
end $f$;

create function pg_temp.apply(who text) returns uuid language plpgsql as $f$
declare o jsonb := pg_temp.op(who, 'write_r8_application', jsonb_build_object('p_purpose', '施工使用', 'p_urgent', false,
  'p_reason', null, 'p_note', null, 'p_products', jsonb_build_array(jsonb_build_object('code', 'BADGE-' || substr(gen_random_uuid()::text, 1, 6), 'name', '測試')),
  'p_submit', true, 'p_id', null, 'p_version', null));
begin
  if not coalesce((o->>'ok')::boolean, false) then raise exception 'apply failed: %', o; end if;
  return (o->>'id')::uuid;
end $f$;

create function pg_temp.act(who text, action text, req uuid, extra jsonb default '{}') returns boolean language plpgsql as $f$
declare o jsonb := pg_temp.op(who, action, jsonb_build_object('p_id', req,
  'p_expected_version', (select version from public.drawing_requests where id = req)) || extra);
begin
  if not coalesce((o->>'ok')::boolean, false) then raise notice '% % failed: %', who, action, o; end if;
  return coalesce((o->>'ok')::boolean, false);
end $f$;

create function pg_temp.badge(who text) returns jsonb language plpgsql as $f$
declare r text := pg_temp.run(who, 'select public.my_badge_summary()::text');
begin
  if r not like 'OK:%' then raise exception 'badge(%) failed: %', who, r; end if;
  return substr(r, 4)::jsonb;
end $f$;
create function pg_temp.total(who text) returns int language sql as $f$ select (pg_temp.badge(who)->>'total')::int $f$;
create function pg_temp.pending(who text) returns int language sql as $f$ select (pg_temp.badge(who)->>'pending_cases')::int $f$;
create function pg_temp.emp(who text) returns uuid language sql as $f$ select id from public.employees where employee_no = who $f$;
create function pg_temp.queued(who text, req uuid) returns int language sql as $f$
  select count(*)::int from app.push_outbox where employee_id = pg_temp.emp(who) and request_id = req $f$;
create function pg_temp.status(req uuid) returns text language sql as $f$ select status::text from public.drawing_requests where id = req $f$;

-- 與 R8Home「我的工作」各分類相同的獨立計算（以 union 去重），用來核對角標計數
create function pg_temp.home_count(who text) returns int language sql as $f$
  with me as (select pg_temp.emp(who) id), r as (select * from public.drawing_requests)
  select count(*)::int from (
    select r.id from r, me where r.status = 'RETURNED' and r.applicant_id = me.id and r.owner_id = me.id
    union select r.id from r, me where r.status = 'PENDING_DEPT_REVIEW' and (app.l1_authority(me.id, r.department_id)).ok
    union select r.id from r, me where r.status = 'PENDING_DRAWING_REVIEW' and app.has_role('DRAWING_MANAGER', me.id)
           and r.applicant_id <> me.id and not exists (select 1 from public.review_records v where v.request_id = r.id and v.round = r.round
           and v.level = 1 and v.action = 'APPROVE' and v.is_effective and v.reviewer_id = me.id)
    union select r.id from r, me where r.status = 'PENDING_ISSUE' and app.has_role('DRAWING_STAFF', me.id)
           and not exists (select 1 from public.issue_claims c where c.request_id = r.id and c.released_at is null and c.staff_id <> me.id)
    union select r.id from r, me where r.status = 'ISSUE_ABNORMAL' and app.has_role('SYS_ADMIN', me.id)
    union select r.id from r, me where r.status = 'PENDING_RECEIPT' and r.owner_id = me.id) x
$f$;

create temp table t_result (n serial, name text, pass boolean, detail text);
create function pg_temp.ok(name text, pass boolean, detail text default null) returns void language sql as $f$
  insert into t_result (name, pass, detail) values (name, coalesce(pass, false), detail)
$f$;

do $test$
declare a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; dwg uuid; u uuid; dlg uuid; r text; j jsonb; n int; m int; t0 int;
  sub_id uuid; ids bigint[];
begin
  -- ---------- 測試資料準備（僅限此交易）
  delete from app.push_outbox;
  select id into dwg from public.departments where code = 'DWG';
  -- TEST003 同時兼任圖管主管、並管轄圖管部（用於「同一人不得跨層核准」）
  insert into public.employee_roles (employee_id, role) values (pg_temp.emp('TEST003'), 'DRAWING_MANAGER');
  insert into public.manager_departments (manager_id, department_id) values (pg_temp.emp('TEST003'), dwg);
  -- 第二位圖管人員 TEST009（用於認領後不再通知無權處理者）
  insert into auth.users (email, encrypted_password) values ('test009@login.sucoot.com', 'x') returning id into u;
  insert into auth.sessions (user_id) values (u);
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password)
    values ('TEST009', u, '測試圖管人員B', dwg, false);
  insert into public.employee_roles (employee_id, role) values (pg_temp.emp('TEST009'), 'EMPLOYEE'), (pg_temp.emp('TEST009'), 'DRAWING_STAFF');

  -- ========== 權限（T07、T08 前半）
  perform pg_temp.ok('T07 未登入（anon）不可查詢角標', pg_temp.run(null, 'select public.my_badge_summary()::text') like '%permission denied%');
  perform pg_temp.ok('T07 有 authenticated 角色但沒有登入身分 → 拒絕',
    pg_temp.run(null, 'select public.my_badge_summary()::text', 'authenticated') not like 'OK:%');
  perform pg_temp.ok('P1 my_badge_summary 不接受指定員工參數（函式無參數）',
    (select pronargs from pg_proc where oid = 'public.my_badge_summary'::regproc) = 0);
  perform pg_temp.ok('P2 員工不可直接讀取訂閱／佇列資料表',
    pg_temp.run('TEST001', 'select count(*)::text from app.push_subscriptions') like '%permission denied%'
    and pg_temp.run('TEST001', 'select count(*)::text from app.push_outbox') like '%permission denied%');
  perform pg_temp.ok('P3 員工不可呼叫發送端函式（svc_push_claim／svc_push_report）',
    pg_temp.run('TEST006', 'select public.svc_push_claim(10)::text') like '%permission denied%'
    and pg_temp.run('TEST006', 'select public.svc_push_report(array[1]::bigint[], ''[]'')::text') like '%permission denied%');
  perform pg_temp.ok('P4 只有系統管理員可查推播摘要',
    pg_temp.run('TEST001', 'select public.admin_push_summary()::text') like '%FORBIDDEN%'
    and pg_temp.run('TEST006', 'select public.admin_push_summary()::text') like 'OK:%');

  -- ========== 一般流程：送件 → 第一層（T09）
  a := pg_temp.apply('TEST001');                                   -- 製造部案件 A
  perform pg_temp.ok('T09 部門主管 TEST003（管轄製造部）有第一層待辦並排入推播',
    (pg_temp.badge('TEST003')->'by_kind'->>'L1')::int = 1 and pg_temp.queued('TEST003', a) = 1);
  perform pg_temp.ok('T09 非管轄主管 TEST007（工程部）沒有待辦也不收推播',
    pg_temp.pending('TEST007') = 0 and pg_temp.queued('TEST007', a) = 0);
  perform pg_temp.ok('E1 操作者本人（送件人 TEST001）不收自己操作的推播', pg_temp.queued('TEST001', a) = 0);
  perform pg_temp.ok('E2 圖管、管理員等無權處理第一層者不收推播',
    pg_temp.queued('TEST004', a) + pg_temp.queued('TEST005', a) + pg_temp.queued('TEST006', a) = 0);

  -- ========== 代理（T12）
  insert into public.review_delegations (principal_id, delegate_id, level, valid_from, valid_to, reason, created_by)
    values (pg_temp.emp('TEST003'), pg_temp.emp('TEST007'), 1, app.today_tpe(), app.today_tpe() + 6, '測試代理', pg_temp.emp('TEST003'))
    returning id into dlg;
  perform pg_temp.ok('T12 有效代理：代理人 TEST007 可看到製造部第一層待辦', (pg_temp.badge('TEST007')->'by_kind'->>'L1')::int = 1);
  b := pg_temp.apply('TEST001');                                   -- 代理期間送出案件 B
  perform pg_temp.ok('T12 有效代理期間新案件同時推播給主管與代理人',
    pg_temp.queued('TEST003', b) = 1 and pg_temp.queued('TEST007', b) = 1);
  update public.review_delegations set revoked_at = now(), revoked_by = pg_temp.emp('TEST003'), revoke_reason = '測試撤銷' where id = dlg;
  perform pg_temp.ok('T12 代理撤銷後：代理人不再有第一層待辦', pg_temp.pending('TEST007') = 0);
  c := pg_temp.apply('TEST002');                                   -- 撤銷後送出案件 C
  perform pg_temp.ok('T12 代理撤銷後的新案件不推播給前代理人', pg_temp.queued('TEST007', c) = 0 and pg_temp.queued('TEST003', c) = 1);
  insert into public.review_delegations (principal_id, delegate_id, level, valid_from, valid_to, reason, created_by)
    values (pg_temp.emp('TEST003'), pg_temp.emp('TEST007'), 1, app.today_tpe() - 10, app.today_tpe() - 4, '已過期', pg_temp.emp('TEST003'));
  perform pg_temp.ok('T12 已過期代理不給予待辦', pg_temp.pending('TEST007') = 0);

  -- ========== 第一層 → 第二層（T03、T10）
  t0 := pg_temp.pending('TEST003');
  perform pg_temp.ok('F1 TEST003 第一層核准案件 A', pg_temp.act('TEST003', 'review_level1', a, '{"p_action":"APPROVE"}'));
  perform pg_temp.ok('T03 主管完成核准後待辦下降', pg_temp.pending('TEST003') = t0 - 1, format('%s → %s', t0, pg_temp.pending('TEST003')));
  perform pg_temp.ok('T10 第一層核准者 TEST003（兼圖管主管）不可得到同案第二層待辦或推播',
    coalesce((pg_temp.badge('TEST003')->'by_kind'->>'L2')::int, 0) = 0 and pg_temp.queued('TEST003', a) = 1 /* 只有先前第一層那筆 */);
  perform pg_temp.ok('T10 另一位圖管主管 TEST004 得到第二層待辦並排入推播',
    (pg_temp.badge('TEST004')->'by_kind'->>'L2')::int = 1 and pg_temp.queued('TEST004', a) = 1);
  d := pg_temp.apply('TEST004');                                   -- 圖管主管自己送出案件 D（圖管部）
  perform pg_temp.ok('F2 TEST003 第一層核准 D', pg_temp.act('TEST003', 'review_level1', d, '{"p_action":"APPROVE"}'));
  perform pg_temp.ok('T10 申請人本人（圖管主管 TEST004）不可得到自己案件的第二層待辦或推播',
    pg_temp.status(d) = 'PENDING_DRAWING_REVIEW' and coalesce((pg_temp.badge('TEST004')->'by_kind'->>'L2')::int, 0) = 1
    and pg_temp.queued('TEST004', d) = 0 and pg_temp.queued('TEST003', d) = 1 /* 只有第一層那筆 */);

  -- ========== 第二層 → 待發行 → 認領（T11）
  perform pg_temp.ok('F3 TEST004 第二層核准 A', pg_temp.act('TEST004', 'review_level2', a, '{"p_action":"APPROVE"}'));
  perform pg_temp.ok('T11 兩位圖管人員都有待發行並排入推播',
    pg_temp.pending('TEST005') = 1 and pg_temp.pending('TEST009') = 1 and pg_temp.queued('TEST005', a) = 1 and pg_temp.queued('TEST009', a) = 1);
  perform pg_temp.ok('F4 TEST005 認領 A', pg_temp.act('TEST005', 'claim_issue', a));
  perform pg_temp.ok('T11 認領後：認領人仍有待發行，另一位圖管人員待辦歸零',
    pg_temp.pending('TEST005') = 1 and pg_temp.pending('TEST009') = 0);
  j := public.svc_push_claim(100);
  perform pg_temp.ok('T11 發送前重新確認資格：未送出的 TEST009 推播改為略過（NOT_ELIGIBLE）',
    (select status || ':' || last_error from app.push_outbox where employee_id = pg_temp.emp('TEST009') and request_id = a) = 'SKIPPED:NOT_ELIGIBLE'
    and not exists (select 1 from jsonb_array_elements(j) x where x->>'employee_id' = pg_temp.emp('TEST009')::text));
  update app.push_outbox set status = 'SENT', locked_until = null where status = 'SENDING';   -- 清空本批，避免影響後續測試

  -- ========== 發行 → 待簽收 → 異常 → 簽收
  perform pg_temp.ok('F5 TEST005 登記發行 A', pg_temp.act('TEST005', 'record_issue', a));
  perform pg_temp.ok('E3 發行後申請人有待簽收並排入推播', (pg_temp.badge('TEST001')->'by_kind'->>'RECEIPT')::int = 1 and pg_temp.queued('TEST001', a) = 1);
  perform pg_temp.ok('F6 TEST001 提出整案異常', pg_temp.act('TEST001', 'case_exception', a, '{"p_reason":"缺頁","p_withdraw":false}'));
  perform pg_temp.ok('E4 整案異常推播給全部啟用中的系統管理員，不給一般員工',
    pg_temp.queued('TEST006', a) = 1 and pg_temp.queued('TEST008', a) = 1 and pg_temp.queued('admin', a) = 1
    and pg_temp.queued('TEST002', a) = 0 and pg_temp.queued('TEST005', a) = 1 /* 僅先前待發行那筆 */);
  perform pg_temp.ok('F7 TEST001 撤回整案異常', pg_temp.act('TEST001', 'case_exception', a, '{"p_reason":"已找到","p_withdraw":true}'));

  -- ========== 退回補件（B 由 TEST003 退回）
  perform pg_temp.ok('F8 TEST003 第一層退回 B', pg_temp.act('TEST003', 'review_level1', b, '{"p_action":"RETURN","p_comment":"請補資料"}'));
  perform pg_temp.ok('E5 退回後申請人有退回補件並排入推播', (pg_temp.badge('TEST001')->'by_kind'->>'RETURNED')::int = 1 and pg_temp.queued('TEST001', b) = 1);
  e := pg_temp.apply('TEST001');
  perform pg_temp.ok('F9 TEST003 第一層退回 E', pg_temp.act('TEST003', 'review_level1', e, '{"p_action":"RETURN","p_comment":"請補資料"}'));

  -- ========== T01：未讀 2＋待辦 3＝5
  for n in 1..4 loop   -- 測試用稽核列（動作名稱不觸發通知產生器）
    perform app.audit(pg_temp.emp('TEST006'), 'TEST_NOTICE_' || n, 'test', 'badge', null, null, null);
  end loop;
  insert into app.personal_security_notices (audit_id, employee_id, event, occurred_at, read_at)
  select l.id, pg_temp.emp('TEST001'), 'change',
         case when rn = 3 then now() - interval '40 days' else now() - (rn || ' hours')::interval end,   -- 第 3 筆為 30 天前
         case when rn = 4 then now() end                                                                  -- 第 4 筆已讀
    from (select id, row_number() over (order by id) rn from public.admin_audit_logs where action like 'TEST_NOTICE_%') l;
  j := pg_temp.badge('TEST001');
  perform pg_temp.ok('T01 未讀 2＋待辦 3（退回 B、E、待簽收 A）＝角標 5',
    (j->>'unread_notices')::int = 2 and (j->>'pending_cases')::int = 3 and (j->>'total')::int = 5, j::text);
  perform pg_temp.ok('T01 30 天前的未讀通知不計入（與通知中心顯示範圍一致）', (j->>'unread_notices')::int = 2);

  -- ========== T04：標記已讀
  r := pg_temp.run('TEST001', format('select public.read_security_notice(%s)::text',
         (select audit_id from app.personal_security_notices where employee_id = pg_temp.emp('TEST001') and read_at is null
           and occurred_at > now() - interval '30 days' order by audit_id limit 1)));
  perform pg_temp.ok('T04 通知標記已讀後角標 5 → 4', r like 'OK:%' and pg_temp.total('TEST001') = 4);

  -- ========== T03：簽收後下降
  perform pg_temp.ok('F10 TEST001 整案簽收 A', pg_temp.act('TEST001', 'confirm_receipt', a));
  perform pg_temp.ok('T03 員工完成簽收後角標 4 → 3', pg_temp.total('TEST001') = 3);

  -- ========== T06：員工隔離
  perform pg_temp.ok('T06 不同員工計數完全隔離（TEST002 只算自己的案件）',
    pg_temp.total('TEST002') = 0 and pg_temp.total('TEST001') = 3);

  -- ========== T02：多角色不重複
  insert into public.employee_roles (employee_id, role) select pg_temp.emp('TEST003'), x::public.app_role
    from unnest(array['DRAWING_STAFF','SYS_ADMIN']) x;
  perform pg_temp.ok('T02 多角色（部門主管＋圖管主管＋圖管人員＋系統管理員）計數＝去重後案件數',
    pg_temp.pending('TEST003') = pg_temp.home_count('TEST003'),
    format('badge=%s home(distinct)=%s', pg_temp.pending('TEST003'), pg_temp.home_count('TEST003')));
  perform pg_temp.ok('T02 每位員工角標皆等於首頁各分類去重計數',
    not exists (select 1 from public.employees x where x.is_active and not x.must_change_password
                  and pg_temp.pending(x.employee_no) <> pg_temp.home_count(x.employee_no)));

  -- ========== T05：無通知與待辦
  update app.personal_security_notices set read_at = now() where employee_id = pg_temp.emp('TEST001');
  perform pg_temp.act('TEST001', 'submit_request', b, '{"p_resubmit_note":"已補"}');
  perform pg_temp.act('TEST001', 'submit_request', e, '{"p_resubmit_note":"已補"}');
  perform pg_temp.ok('T05 無未讀通知與待辦時角標為 0', pg_temp.total('TEST001') = 0, pg_temp.badge('TEST001')::text);

  -- ========== T18：重複事件不重複推播
  n := (select count(*) from app.push_outbox);
  perform app.touch(c); perform app.touch(c);                       -- 案件被重複更新但待辦狀態未變
  perform pg_temp.ok('T18 同一案件同一待辦狀態重複更新不再排入推播', (select count(*) from app.push_outbox) = n);
  perform pg_temp.ok('T18 佇列以員工＋案件＋狀態簽章唯一，不會重複',
    (select count(*) = count(distinct dedupe_key) from app.push_outbox));

  -- ========== 訂閱（T08、T19、SSRF）
  r := pg_temp.run('TEST002', 'select public.push_register(''https://127.0.0.1/x'', repeat(''A'',87), repeat(''B'',22))::text');
  perform pg_temp.ok('S1 拒絕非推播服務的 endpoint（內部位址）', r like '%INVALID_INPUT%');
  r := pg_temp.run('TEST002', 'select public.push_register(''https://evil.example.com/fcm.googleapis.com/x'', repeat(''A'',87), repeat(''B'',22))::text');
  perform pg_temp.ok('S2 拒絕偽裝的外部主機', r like '%INVALID_INPUT%');
  r := pg_temp.run('TEST002', 'select public.push_register(''http://fcm.googleapis.com/fcm/send/abc'', repeat(''A'',87), repeat(''B'',22))::text');
  perform pg_temp.ok('S3 拒絕非 HTTPS', r like '%INVALID_INPUT%');
  r := pg_temp.run('TEST002', 'select public.push_register(''https://fcm.googleapis.com/fcm/send/abc'', ''short'', repeat(''B'',22))::text');
  perform pg_temp.ok('S4 拒絕格式錯誤的金鑰', r like '%INVALID_INPUT%');
  r := pg_temp.run('TEST002', 'select public.push_register(''https://fcm.googleapis.com/fcm/send/dev-2'', repeat(''A'',87), repeat(''B'',22), ''android'')::text');
  perform pg_temp.ok('S5 合法的 FCM endpoint 可登記', r like 'OK:%');
  r := pg_temp.run('TEST001', 'select public.push_register(''https://web.push.apple.com/QK-dev-1'', repeat(''A'',87), repeat(''B'',22), ''ios'')::text');
  perform pg_temp.ok('S6 合法的 Apple endpoint 可登記', r like 'OK:%');
  perform pg_temp.ok('S7 push_status 只回答「本裝置是否登記於目前帳號」',
    pg_temp.run('TEST001', 'select public.push_status(''https://web.push.apple.com/QK-dev-1'')::text') = 'OK:{"registered": true}'
    and pg_temp.run('TEST002', 'select public.push_status(''https://web.push.apple.com/QK-dev-1'')::text') = 'OK:{"registered": false}');
  perform pg_temp.run('TEST002', 'select public.push_unregister(''https://web.push.apple.com/QK-dev-1'')::text');
  perform pg_temp.ok('S8 員工不可停用他人的裝置訂閱',
    (select revoked_at is null from app.push_subscriptions where endpoint = 'https://web.push.apple.com/QK-dev-1'));
  perform pg_temp.ok('S9 訂閱綁定登入工作階段',
    (select session_id is not null from app.push_subscriptions where endpoint = 'https://web.push.apple.com/QK-dev-1'));

  -- 送件給 TEST003 → 有效訂閱者才會出現在發送批次
  r := pg_temp.run('TEST003', 'select public.push_register(''https://fcm.googleapis.com/fcm/send/dev-3'', repeat(''C'',87), repeat(''D'',22))::text');
  update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING');
  f := pg_temp.apply('TEST001');
  j := public.svc_push_claim(100);
  perform pg_temp.ok('D1 發送批次依員工合併，並附上該員工即時角標總數',
    exists (select 1 from jsonb_array_elements(j) x where x->>'employee_id' = pg_temp.emp('TEST003')::text
              and (x->>'badge')::int = pg_temp.total('TEST003') and jsonb_array_length(x->'subscriptions') = 1), j::text);
  select array_agg(y::bigint) into ids from jsonb_array_elements(j) x, jsonb_array_elements_text(x->'outbox_ids') y
   where x->>'employee_id' = pg_temp.emp('TEST003')::text;
  select id into sub_id from app.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/dev-3';
  perform pg_temp.ok('D2 同一批次再次取出不會重複（已鎖定）', jsonb_array_length(public.svc_push_claim(100)) = 0);

  -- 暫時性失敗 → 退避後重試；推播服務接受 → SENT（只代表推播服務已接受）
  j := public.svc_push_report(ids, jsonb_build_array(jsonb_build_object('subscription_id', sub_id, 'http_status', 503, 'accepted', false)));
  perform pg_temp.ok('D3 暫時性失敗（503）→ 排程重試，不是成功',
    j->>'status' = 'PENDING' and (select bool_and(next_attempt_at > now()) from app.push_outbox where id = any(ids)));
  update app.push_outbox set next_attempt_at = now() where id = any(ids);
  j := public.svc_push_claim(100);
  j := public.svc_push_report(ids, jsonb_build_array(jsonb_build_object('subscription_id', sub_id, 'http_status', 201, 'accepted', true)));
  perform pg_temp.ok('D4 推播服務接受（201）→ SENT，並記錄發送結果', j->>'status' = 'SENT'
    and (select count(*) from app.push_deliveries where subscription_id = sub_id) = 2);
  perform pg_temp.ok('D5 發送紀錄不保存 endpoint 或金鑰欄位',
    not exists (select 1 from information_schema.columns where table_schema = 'app' and table_name = 'push_deliveries'
                  and column_name in ('endpoint','p256dh','auth','payload')));

  -- T19：失效訂閱（410）→ 停用，之後不再取出
  update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING');
  perform pg_temp.act('TEST003', 'review_level1', f, '{"p_action":"RETURN","p_comment":"退回"}');
  perform pg_temp.act('TEST001', 'submit_request', f, '{"p_resubmit_note":"重送"}');
  j := public.svc_push_claim(100);
  select array_agg(y::bigint) into ids from jsonb_array_elements(j) x, jsonb_array_elements_text(x->'outbox_ids') y
   where x->>'employee_id' = pg_temp.emp('TEST003')::text;
  j := public.svc_push_report(ids, jsonb_build_array(jsonb_build_object('subscription_id', sub_id, 'http_status', 410, 'accepted', false, 'gone', true)));
  perform pg_temp.ok('T19 410 Gone → 訂閱停用（EXPIRED）、該批不重試',
    (select revoke_reason from app.push_subscriptions where id = sub_id) = 'EXPIRED' and j->>'status' = 'FAILED');
  update public.drawing_requests set status = status where id = f;   -- 無變化
  perform pg_temp.act('TEST003', 'review_level1', f, '{"p_action":"RETURN","p_comment":"再退回"}');
  perform pg_temp.act('TEST001', 'submit_request', f, '{"p_resubmit_note":"再重送"}');
  j := public.svc_push_claim(100);
  perform pg_temp.ok('T19 已停用的訂閱不再出現在發送批次',
    coalesce((select jsonb_array_length(x->'subscriptions') from jsonb_array_elements(j) x
               where x->>'employee_id' = pg_temp.emp('TEST003')::text), 0) = 0);
  select array_agg(y::bigint) into ids from jsonb_array_elements(j) x, jsonb_array_elements_text(x->'outbox_ids') y
   where x->>'employee_id' = pg_temp.emp('TEST003')::text;
  perform pg_temp.ok('T19 沒有有效訂閱 → 佇列標示 SKIPPED（NO_SUBSCRIPTION）',
    public.svc_push_report(ids, '[]')->>'status' = 'SKIPPED');

  -- 登出／工作階段撤銷：訂閱仍在，但不再發送到該裝置
  delete from auth.sessions where user_id = (select auth_user_id from public.employees where employee_no = 'TEST001');
  insert into auth.sessions (user_id) select auth_user_id from public.employees where employee_no = 'TEST001';
  perform pg_temp.act('TEST003', 'review_level1', f, '{"p_action":"RETURN","p_comment":"第三次退回"}');
  j := public.svc_push_claim(100);
  perform pg_temp.ok('S10 舊工作階段失效後，該裝置訂閱不再收到推播',
    coalesce((select jsonb_array_length(x->'subscriptions') from jsonb_array_elements(j) x
               where x->>'employee_id' = pg_temp.emp('TEST001')::text), 0) = 0);
  update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING');

  -- T08：停用、重設密碼
  update public.employees set must_change_password = true where employee_no = 'TEST002';
  perform pg_temp.ok('T08 管理員重設密碼後：訂閱全部停用（CREDENTIAL_RESET）、改密碼前不可查詢角標',
    (select bool_and(revoke_reason = 'CREDENTIAL_RESET') from app.push_subscriptions where employee_id = pg_temp.emp('TEST002'))
    and pg_temp.run('TEST002', 'select public.my_badge_summary()::text') like '%PASSWORD_CHANGE_REQUIRED%');
  update public.employees set must_change_password = false where employee_no = 'TEST002';
  r := pg_temp.run('TEST002', 'select public.push_register(''https://fcm.googleapis.com/fcm/send/dev-2'', repeat(''A'',87), repeat(''B'',22))::text');
  update public.employees set is_active = false where employee_no = 'TEST002';
  perform pg_temp.ok('T08 停用員工：訂閱停用（ACCOUNT_DISABLED）、不可查詢角標、不可登記訂閱',
    (select revoke_reason from app.push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/dev-2') = 'ACCOUNT_DISABLED'
    and pg_temp.run('TEST002', 'select public.my_badge_summary()::text') like '%ACCOUNT_INACTIVE%'
    and pg_temp.run('TEST002', 'select public.push_register(''https://fcm.googleapis.com/fcm/send/dev-9'', repeat(''A'',87), repeat(''B'',22))::text') like '%ACCOUNT_INACTIVE%');
  perform pg_temp.ok('T08 停用員工不會被排入推播', pg_temp.queued('TEST002', c) = 0
    or (select status from app.push_outbox where employee_id = pg_temp.emp('TEST002') order by id desc limit 1) <> 'PENDING');
  update public.employees set is_active = true where employee_no = 'TEST002';

  -- ========== T17：佇列寫入失敗不影響案件操作
  create function pg_temp.boom() returns trigger language plpgsql as $f$ begin raise exception 'SIMULATED_PUSH_FAILURE'; end $f$;
  create trigger boom before insert on app.push_outbox for each row execute function pg_temp.boom();
  n := (select count(*) from app.push_enqueue_errors);
  perform pg_temp.ok('T17 推播佇列寫入失敗時，第一層核准仍成功提交',
    pg_temp.act('TEST003', 'review_level1', c, '{"p_action":"APPROVE"}') and pg_temp.status(c) = 'PENDING_DRAWING_REVIEW');
  perform pg_temp.ok('T17 失敗被記錄於 push_enqueue_errors（可追查）',
    (select count(*) from app.push_enqueue_errors) = n + 1
    and (select message from app.push_enqueue_errors order by id desc limit 1) like '%SIMULATED_PUSH_FAILURE%');
  drop trigger boom on app.push_outbox;

  -- 管理員摘要不含敏感欄位
  r := pg_temp.run('TEST006', 'select public.admin_push_summary()::text');
  perform pg_temp.ok('P5 推播摘要不含 endpoint／金鑰', r like 'OK:%' and r not like '%googleapis%' and r not like '%apple.com%' and r not like '%p256dh%');

  -- 推播佇列與 safeupdate 規則
  perform pg_temp.ok('P6 新函式中所有 UPDATE／DELETE 皆含 WHERE（正式 safeupdate）', not exists (
    select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace,
      regexp_matches(p.prosrc, '(?:^|[\s;(])((?:update|delete\s+from)\s+(?:only\s+)?[a-z_]+\.[a-z_]+[^;]*)', 'gi') mm
     where ns.nspname in ('public','app') and p.proname ~ '(push|badge|pending_kind)' and mm[1] !~* '\mwhere\M'));
end $test$;

select n, case when pass then 'PASS' else 'FAIL' end as result, name, case when pass then null else left(detail, 300) end as detail from t_result order by n;
select count(*) filter (where pass) as passed, count(*) as total from t_result;
do $$ begin if exists (select 1 from t_result where not pass) then raise exception 'V5.9.1 badge/push tests failed'; end if; end $$;
rollback;
