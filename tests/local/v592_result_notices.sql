-- SUCOOT V5.9.2｜案件結果通知（駁回、強制結案、取消、簽收完成）：後端隔離測試
-- 執行：psql -v ON_ERROR_STOP=1 -f tests/local/v592_result_notices.sql（交易內執行並回滾）
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


-- 以管理員身分直接呼叫（admin_transfer_owner 不開放 authenticated 直接呼叫）
create function pg_temp.admin_call(sql text) returns text language plpgsql as $f$
declare v text;
begin
  perform set_config('request.jwt.claims', (select jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text
    from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
   where e.employee_no = 'TEST006'), true);
  begin execute sql into v; v := 'OK:' || coalesce(v, ''); exception when others then v := sqlerrm; end;
  perform set_config('request.jwt.claims', '', true);
  return v;
end $f$;
create function pg_temp.notices(who text, req uuid) returns text language sql as $f$
  select coalesce(string_agg(kind, ',' order by kind), '') from app.case_notices where employee_id = pg_temp.emp(who) and request_id = req $f$;
create function pg_temp.rq(who text, req uuid) returns text language sql as $f$
  select coalesce(string_agg(kind, ',' order by kind), '') from app.push_outbox where employee_id = pg_temp.emp(who) and request_id = req and kind like 'R\_%' $f$;
create function pg_temp.all_notices(req uuid) returns text language sql as $f$
  select coalesce(string_agg(e.employee_no || ':' || c.kind, ',' order by e.employee_no), '') from app.case_notices c join public.employees e on e.id = c.employee_id where c.request_id = req $f$;
create function pg_temp.count_notices(who text, req uuid) returns text language sql as $f$
  select pg_temp.run(who, format('select count(*)::text from public.my_case_notices() x where x.request_id = %L', req)) $f$;

do $test$
declare a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; r text; j jsonb; n int; dlg uuid; t0 int;
begin
  delete from app.push_outbox;
  -- ========== 駁回 → 申請人（＝負責人）
  a := pg_temp.apply('TEST001');
  perform pg_temp.ok('F1 TEST003 第一層駁回 A', pg_temp.act('TEST003', 'review_level1', a, '{"p_action":"REJECT","p_comment":"不符規定"}'));
  perform pg_temp.ok('R1 駁回：申請人收到「申請已駁回」通知與推播', pg_temp.notices('TEST001', a) = 'R_REJECTED' and pg_temp.rq('TEST001', a) = 'R_REJECTED');
  perform pg_temp.ok('R2 駁回：操作者（駁回的主管）與其他人不收到', pg_temp.all_notices(a) = 'TEST001:R_REJECTED', pg_temp.all_notices(a));
  j := pg_temp.badge('TEST001');
  perform pg_temp.ok('R3 角標：未讀案件通知計入（未讀＝安全＋案件）', (j->>'unread_case_notices')::int = 1
    and (j->>'unread_notices')::int = (j->>'unread_security_notices')::int + 1 and (j->>'total')::int = (j->>'unread_notices')::int + (j->>'pending_cases')::int, j::text);

  -- ========== 負責人不同：第二層駁回 → 申請人＋負責人
  b := pg_temp.apply('TEST001');
  r := pg_temp.admin_call(format('select public.admin_transfer_owner(%L, %L, %L)::text', b, pg_temp.emp('TEST002'), '測試移交'));
  perform pg_temp.ok('F2 管理員移交負責人給 TEST002', r like 'OK:%', r);
  perform pg_temp.ok('F3 第一層核准 B', pg_temp.act('TEST003', 'review_level1', b, '{"p_action":"APPROVE"}'));
  perform pg_temp.ok('F4 TEST004 第二層駁回 B', pg_temp.act('TEST004', 'review_level2', b, '{"p_action":"REJECT","p_comment":"圖號錯誤"}'));
  perform pg_temp.ok('R4 第二層駁回：申請人與負責人各收到一則', pg_temp.all_notices(b) = 'TEST001:R_REJECTED,TEST002:R_REJECTED', pg_temp.all_notices(b));

  -- ========== 取消 → 原本待審的主管（含有效代理）
  insert into public.review_delegations (principal_id, delegate_id, level, valid_from, valid_to, reason, created_by)
    values (pg_temp.emp('TEST003'), pg_temp.emp('TEST007'), 1, app.today_tpe(), app.today_tpe() + 6, '代理', pg_temp.emp('TEST003')) returning id into dlg;
  c := pg_temp.apply('TEST001');
  r := pg_temp.run('TEST001', format('select public.cancel_request(%L, %L, %s)::text', c, '不需要了', (select version from public.drawing_requests where id = c)));
  perform pg_temp.ok('F5 TEST001 取消待審中的 C', r like 'OK:%', r);
  perform pg_temp.ok('R5 取消：原本待審的主管與有效代理人收到「申請已取消」', pg_temp.all_notices(c) = 'TEST003:R_CANCELLED,TEST007:R_CANCELLED', pg_temp.all_notices(c));
  perform pg_temp.ok('R6 取消：申請人本人、圖管、管理員不收到', pg_temp.notices('TEST001', c) = '' and pg_temp.notices('TEST004', c) = '' and pg_temp.notices('TEST006', c) = '');
  update public.review_delegations set revoked_at = now(), revoked_by = pg_temp.emp('TEST003'), revoke_reason = '結束' where id = dlg;
  -- 退回補件後取消：沒有待審的主管 → 無人收到
  d := pg_temp.apply('TEST001');
  perform pg_temp.act('TEST003', 'review_level1', d, '{"p_action":"RETURN","p_comment":"補件"}');
  r := pg_temp.run('TEST001', format('select public.cancel_request(%L, %L, %s)::text', d, '不補了', (select version from public.drawing_requests where id = d)));
  perform pg_temp.ok('R7 退回補件狀態取消：沒有待審主管，不產生通知', r like 'OK:%' and pg_temp.all_notices(d) = '', r || ' / ' || pg_temp.all_notices(d));

  -- ========== 簽收完成 → 發行的圖管人員
  e := pg_temp.apply('TEST001');
  perform pg_temp.act('TEST003', 'review_level1', e, '{"p_action":"APPROVE"}');
  perform pg_temp.act('TEST004', 'review_level2', e, '{"p_action":"APPROVE"}');
  perform pg_temp.act('TEST005', 'claim_issue', e);
  perform pg_temp.ok('F6 TEST005 登記發行', pg_temp.act('TEST005', 'record_issue', e));
  perform pg_temp.ok('F7 TEST001 整案簽收', pg_temp.act('TEST001', 'confirm_receipt', e));
  perform pg_temp.ok('R8 簽收完成：只有發行的圖管人員收到「已完成簽收」', pg_temp.all_notices(e) = 'TEST005:R_RECEIPT_DONE', pg_temp.all_notices(e));

  -- ========== 管理員強制結案 → 申請人、負責人
  f := pg_temp.apply('TEST001');
  perform pg_temp.ok('F8 管理員強制結案', pg_temp.act('TEST006', 'admin_force_close', f, '{"p_category":"其他","p_reason":"測試結案"}'));
  perform pg_temp.ok('R9 強制結案：申請人收到「案件已結案」；待審主管與管理員本人不收到', pg_temp.all_notices(f) = 'TEST001:R_FORCE_CLOSED', pg_temp.all_notices(f));

  -- ========== 去重、通知中心、已讀
  n := (select count(*) from app.case_notices);
  perform app.touch(a); perform app.touch(f);
  perform pg_temp.ok('R10 重複更新不重複產生通知', (select count(*) from app.case_notices) = n);
  r := pg_temp.run('TEST001', 'select json_agg(x)::text from public.my_case_notices() x');
  perform pg_temp.ok('R11 我的案件通知：只列本人、含案件編號與類別', r like 'OK:%' and r like '%R_REJECTED%' and r like '%R_FORCE_CLOSED%' and r like '%DR%'
    and r not like '%R_CANCELLED%' and r not like '%R_RECEIPT_DONE%', left(r, 200));
  perform pg_temp.ok('R12 其他員工看不到 TEST001 的通知', pg_temp.count_notices('TEST002', a) = 'OK:0');
  t0 := pg_temp.total('TEST001');
  r := pg_temp.run('TEST002', format('select public.read_case_notice(%s)::text', (select id from app.case_notices where employee_id = pg_temp.emp('TEST001') and request_id = a)));
  perform pg_temp.ok('R13 不可標記他人的通知為已讀', r = 'OK:' and (select read_at is null from app.case_notices where employee_id = pg_temp.emp('TEST001') and request_id = a), r);
  r := pg_temp.run('TEST001', format('select public.read_case_notice(%s)::text', (select id from app.case_notices where employee_id = pg_temp.emp('TEST001') and request_id = a)));
  perform pg_temp.ok('R14 標為已讀後角標下降 1', r like 'OK:2%' and pg_temp.total('TEST001') = t0 - 1, format('%s → %s (%s)', t0, pg_temp.total('TEST001'), r));
  update app.case_notices set occurred_at = now() - interval '31 days' where employee_id = pg_temp.emp('TEST001') and request_id = f;
  perform pg_temp.ok('R15 超過 30 天的通知不顯示、不計入未讀', pg_temp.total('TEST001') = t0 - 2 and pg_temp.count_notices('TEST001', f) = 'OK:0');

  -- ========== 發送資格：結果通知不要求仍有待辦；帳號停用則略過
  update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING');
  a := pg_temp.apply('TEST001');
  perform pg_temp.act('TEST003', 'review_level1', a, '{"p_action":"REJECT","p_comment":"駁回"}');
  j := public.svc_push_claim(100);
  perform pg_temp.ok('R16 結果通知會被取出發送（不要求仍有待辦），類別為 R_REJECTED',
    exists (select 1 from jsonb_array_elements(j) x where x->>'employee_id' = pg_temp.emp('TEST001')::text and x->>'kind' = 'R_REJECTED'), j::text);
  update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING');
  b := pg_temp.apply('TEST002');
  perform pg_temp.act('TEST003', 'review_level1', b, '{"p_action":"REJECT","p_comment":"駁回"}');
  update public.employees set is_active = false where employee_no = 'TEST002';
  j := public.svc_push_claim(100);
  perform pg_temp.ok('R17 收件人排入後停用：結果通知改為略過',
    (select status from app.push_outbox where employee_id = pg_temp.emp('TEST002') and request_id = b) = 'SKIPPED');
  update public.employees set is_active = true where employee_no = 'TEST002';

  -- ========== 權限
  perform pg_temp.ok('P1 未登入不可呼叫 my_case_notices／read_case_notice',
    pg_temp.run(null, 'select count(*)::text from public.my_case_notices()') like '%permission denied%'
    and pg_temp.run(null, 'select public.read_case_notice(1)::text') like '%permission denied%');
  perform pg_temp.ok('P2 員工不可直接讀取 app.case_notices', pg_temp.run('TEST001', 'select count(*)::text from app.case_notices') like '%permission denied%');

  -- ========== 通知寫入失敗不影響業務
  create function pg_temp.boom() returns trigger language plpgsql as $f$ begin raise exception 'SIMULATED_NOTICE_FAILURE'; end $f$;
  create trigger boom before insert on app.case_notices for each row execute function pg_temp.boom();
  n := (select count(*) from app.push_enqueue_errors);
  c := pg_temp.apply('TEST001');
  r := pg_temp.act('TEST003', 'review_level1', c, '{"p_action":"REJECT","p_comment":"駁回"}')::text;
  perform pg_temp.ok('R18 通知寫入失敗時，駁回仍成功提交並記錄錯誤',
    r = 'true' and pg_temp.status(c) = 'REJECTED' and (select count(*) from app.push_enqueue_errors) = n + 1,
    format('act=%s status=%s errors=%s→%s last=%s', r, pg_temp.status(c), n, (select count(*) from app.push_enqueue_errors),
      (select message from app.push_enqueue_errors order by id desc limit 1)));
  drop trigger boom on app.case_notices;

  perform pg_temp.ok('P3 新函式 UPDATE 皆含 WHERE（safeupdate）', not exists (
    select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace,
      regexp_matches(p.prosrc, '(?:^|[\s;(])((?:update|delete\s+from)\s+(?:only\s+)?[a-z_]+\.[a-z_]+[^;]*)', 'gi') mm
     where ns.nspname in ('public','app') and mm[1] !~* '\mwhere\M'));
end $test$;

select n, case when pass then 'PASS' else 'FAIL' end as result, name, case when pass then null else left(detail, 300) end as detail from t_result order by n;
select count(*) filter (where pass) as passed, count(*) as total from t_result;
do $$ begin if exists (select 1 from t_result where not pass) then raise exception 'V5.9.2 result notice tests failed'; end if; end $$;
rollback;
