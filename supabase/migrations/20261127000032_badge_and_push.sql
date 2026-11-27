-- SUCOOT V5.9.1 | PWA 角標（未讀通知＋待辦案件）與背景 Web Push
-- 原則：
--   * 「誰有待辦」只在 app.pending_kind 判斷一次，條件逐條對應既有業務 RPC 的權限檢查
--     （review_level1／review_level2／claim_issue／record_issue／confirm_receipt／submit_request），
--     角標計數與推播收件人共用同一判斷，避免兩邊規則不一致。
--   * 不修改任何既有業務 RPC、RLS 或權限；只新增唯讀 RPC、裝置訂閱 RPC 與推播佇列。
--   * 推播佇列由 drawing_requests 的 AFTER UPDATE 觸發器產生，並以例外處理包住：
--     佇列寫入失敗不會讓原本成功的審核、發行、簽收交易回滾。
--   * 訂閱與佇列放在 app schema（PostgREST 不公開）；員工只能透過 RPC 管理「自己的」訂閱，
--     推播發送端（Edge Function）只能以 service_role 呼叫 svc_push_* 函式。
--   * 所有 UPDATE／DELETE 皆含 WHERE（正式環境啟用 safeupdate）。

-- ================================================================ 待辦判斷（單一來源）
-- 回傳此員工對此案件的待辦類別；不是待辦則回傳 null。
--   RETURNED  退回補件：申請人本人且仍為負責人（submit_request）
--   L1        第一層待審：具該部門第一層權限（本人管轄或有效代理，app.l1_authority）（review_level1）
--   L2        第二層待審：圖管主管、非申請人、非本輪第一層核准者（review_level2）
--   ISSUE     圖面待發行：圖管人員，且尚無人認領或由本人認領（claim_issue／record_issue）
--   ABNORMAL  整案異常待辦：系統管理員
--   RECEIPT   待簽收：案件負責人（confirm_receipt）
-- 一個案件在同一時間只有一個狀態，因此對同一員工最多只會落在一個類別，多角色不會重複計數。
create or replace function app.pending_kind(p_emp uuid, r public.drawing_requests) returns text
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_emp is null or not exists (select 1 from public.employees e where e.id = p_emp and e.is_active) then
    return null;
  end if;
  case r.status
    when 'RETURNED' then
      if r.applicant_id = p_emp and r.owner_id = p_emp then return 'RETURNED'; end if;
    when 'PENDING_DEPT_REVIEW' then
      if (app.l1_authority(p_emp, r.department_id)).ok then return 'L1'; end if;
    when 'PENDING_DRAWING_REVIEW' then
      if app.has_role('DRAWING_MANAGER', p_emp) and r.applicant_id <> p_emp
         and not exists (select 1 from public.review_records v
                          where v.request_id = r.id and v.round = r.round and v.level = 1
                            and v.action = 'APPROVE' and v.is_effective and v.reviewer_id = p_emp) then
        return 'L2';
      end if;
    when 'PENDING_ISSUE' then
      if app.has_role('DRAWING_STAFF', p_emp)
         and not exists (select 1 from public.issue_claims c
                          where c.request_id = r.id and c.released_at is null and c.staff_id <> p_emp) then
        return 'ISSUE';
      end if;
    when 'ISSUE_ABNORMAL' then
      if app.has_role('SYS_ADMIN', p_emp) then return 'ABNORMAL'; end if;
    when 'PENDING_RECEIPT' then
      if r.owner_id = p_emp then return 'RECEIPT'; end if;
    else
      null;
  end case;
  return null;
end $$;

-- 指定員工的角標計數（內部使用；不接受前端指定員工）
create or replace function app.badge_counts(p_emp uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with pending as (
    select app.pending_kind(p_emp, r) as kind
      from public.drawing_requests r
     where r.status in ('RETURNED','PENDING_DEPT_REVIEW','PENDING_DRAWING_REVIEW','PENDING_ISSUE','ISSUE_ABNORMAL','PENDING_RECEIPT')
  ), cases as (
    select kind, count(*)::int n from pending where kind is not null group by kind
  ), unread as (
    -- 與 my_security_notices 相同範圍：本人、最近 30 天、未讀
    select count(*)::int n from app.personal_security_notices s
     where s.employee_id = p_emp and s.read_at is null and s.occurred_at >= now() - interval '30 days'
  )
  select jsonb_build_object(
    'unread_notices', (select n from unread),
    'pending_cases', coalesce((select sum(n) from cases), 0)::int,
    'total', (select n from unread) + coalesce((select sum(n) from cases), 0)::int,
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from cases), '{}'::jsonb),
    'as_of', now())
$$;

-- 員工：取得自己的角標計數（唯讀；身分一律取自登入工作階段）
create or replace function public.my_badge_summary() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.require_employee();   -- 未登入、停用、工作階段失效、需先改密碼 → 拒絕
begin
  return app.badge_counts(me);
end $$;

-- ================================================================ 裝置推播訂閱
create table app.push_subscriptions (
  id              uuid primary key default gen_random_uuid(),
  employee_id     uuid not null references public.employees(id),
  session_id      uuid,                      -- 建立／更新時的登入工作階段；工作階段失效即不再發送
  endpoint        text not null unique check (length(endpoint) between 20 and 1024),
  p256dh          text not null check (p256dh ~ '^[A-Za-z0-9_-]{86,88}$'),
  auth            text not null check (auth ~ '^[A-Za-z0-9_-]{21,24}$'),
  platform        text check (length(platform) <= 40),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  revoked_at      timestamptz,
  revoke_reason   text,
  failure_count   int not null default 0,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_status     int
);
create index push_subscriptions_employee_idx on app.push_subscriptions (employee_id) where revoked_at is null;
alter table app.push_subscriptions enable row level security;
revoke all on app.push_subscriptions from public, anon, authenticated;

-- 只接受已知瀏覽器推播服務的 HTTPS 網址（防止以使用者可控的 endpoint 讓伺服器連線任意主機）
create or replace function app.push_endpoint_allowed(p_endpoint text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_endpoint, '') ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|web\.push\.apple\.com|[a-z0-9-]+\.push\.apple\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.notify\.windows\.com)/[!-~]+$'
$$;

-- 員工：登記（或更新）本裝置的推播訂閱
create or replace function public.push_register(p_endpoint text, p_p256dh text, p_auth text, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.require_employee(); sid uuid := nullif(auth.jwt()->>'session_id', '')::uuid; v_id uuid;
begin
  if not app.push_endpoint_allowed(p_endpoint) or length(p_endpoint) > 1024 then
    perform app.err('INVALID_INPUT', '不支援的推播服務');
  end if;
  if coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{86,88}$' or coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{21,24}$' then
    perform app.err('INVALID_INPUT', '推播金鑰格式錯誤');
  end if;
  -- 同一裝置換帳號登入：endpoint 改歸目前員工（原員工不再收到此裝置的通知）
  insert into app.push_subscriptions (employee_id, session_id, endpoint, p256dh, auth, platform)
  values (me, sid, p_endpoint, p_p256dh, p_auth, left(nullif(btrim(p_platform), ''), 40))
  on conflict (endpoint) do update set employee_id = excluded.employee_id, session_id = excluded.session_id,
       p256dh = excluded.p256dh, auth = excluded.auth, platform = excluded.platform, updated_at = now(),
       revoked_at = null, revoke_reason = null, failure_count = 0
  returning id into v_id;
  -- 每位員工最多保留 10 個有效裝置，超過時停用最舊的
  update app.push_subscriptions set revoked_at = now(), revoke_reason = 'DEVICE_LIMIT'
   where id in (select id from app.push_subscriptions where employee_id = me and revoked_at is null
                 order by updated_at desc offset 10);
  return jsonb_build_object('registered', true);
end $$;

-- 員工：停用本裝置的推播（登出、使用者關閉通知時呼叫）；只能停用自己的訂閱
create or replace function public.push_unregister(p_endpoint text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.current_employee_id();   -- 登出流程中工作階段可能已將失效：失效時不做事也不報錯
begin
  if me is not null then
    update app.push_subscriptions set revoked_at = now(), revoke_reason = 'USER', updated_at = now()
     where endpoint = p_endpoint and employee_id = me and revoked_at is null;
  end if;
  return jsonb_build_object('registered', false);
end $$;

-- 員工：本裝置是否已登記於目前帳號（不回傳任何 endpoint 或金鑰）
create or replace function public.push_status(p_endpoint text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.require_employee();
begin
  return jsonb_build_object('registered', exists (select 1 from app.push_subscriptions s
    where s.endpoint = p_endpoint and s.employee_id = me and s.revoked_at is null));
end $$;

-- 帳號停用、管理員重設密碼、重新啟用（須強制改密碼）時，停用該員工全部裝置訂閱
create or replace function app.revoke_employee_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update app.push_subscriptions set revoked_at = now(), updated_at = now(),
         revoke_reason = case when not new.is_active then 'ACCOUNT_DISABLED' else 'CREDENTIAL_RESET' end
   where employee_id = new.id and revoked_at is null;
  return new;
end $$;
create trigger revoke_push_on_disable after update of is_active on public.employees
  for each row when (old.is_active and not new.is_active) execute function app.revoke_employee_push();
create trigger revoke_push_on_credential_reset after update of must_change_password on public.employees
  for each row when (new.must_change_password and not old.must_change_password) execute function app.revoke_employee_push();

-- ================================================================ 推播佇列
create table app.push_outbox (
  id              bigserial primary key,
  employee_id     uuid not null references public.employees(id),
  request_id      uuid not null references public.drawing_requests(id),
  kind            text not null,
  dedupe_key      text not null unique,
  created_at      timestamptz not null default now(),
  status          text not null default 'PENDING' check (status in ('PENDING','SENDING','SENT','FAILED','SKIPPED')),
  attempts        int not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until    timestamptz,
  sent_at         timestamptz,
  accepted_count  int not null default 0,
  failed_count    int not null default 0,
  last_error      text
);
create index push_outbox_due_idx on app.push_outbox (next_attempt_at) where status in ('PENDING','SENDING');
alter table app.push_outbox enable row level security;
revoke all on app.push_outbox from public, anon, authenticated;

-- 每次送往推播服務的結果（只記錄狀態碼與摘要，不記錄 endpoint、金鑰或通知內容）
create table app.push_deliveries (
  id              bigserial primary key,
  outbox_ids      bigint[] not null,
  subscription_id uuid not null references app.push_subscriptions(id),
  http_status     int,
  accepted        boolean not null,
  error           text check (length(error) <= 200),
  created_at      timestamptz not null default now()
);
alter table app.push_deliveries enable row level security;
revoke all on app.push_deliveries from public, anon, authenticated;

-- 觸發器無法寫入佇列時的紀錄（不影響業務交易）
create table app.push_enqueue_errors (
  id         bigserial primary key,
  request_id uuid,
  sqlstate   text,
  message    text,
  created_at timestamptz not null default now()
);
alter table app.push_enqueue_errors enable row level security;
revoke all on app.push_enqueue_errors from public, anon, authenticated;

-- 案件異動後：找出「現在」對此案件有待辦的員工，排入推播佇列
-- 排除本次操作者；同一員工、同一案件、同一狀態簽章只排一次（重複事件不重複推播）
create or replace function app.enqueue_push_for_request() returns trigger
language plpgsql security definer set search_path = '' as $$
declare actor uuid; claim uuid; sig text;
begin
  begin
    actor := app.current_employee_id();
    select c.id into claim from public.issue_claims c where c.request_id = new.id and c.released_at is null;
    sig := new.id || ':' || new.status || ':' || new.round || ':' || new.owner_id || ':' || coalesce(claim::text, '-');
    insert into app.push_outbox (employee_id, request_id, kind, dedupe_key)
    select e.id, new.id, k.kind, sig || ':' || e.id
      from public.employees e
      cross join lateral (select app.pending_kind(e.id, new) as kind) k
     where e.is_active and k.kind is not null and e.id is distinct from actor
    on conflict (dedupe_key) do nothing;
  exception when others then
    begin
      insert into app.push_enqueue_errors (request_id, sqlstate, message) values (new.id, sqlstate, left(sqlerrm, 300));
    exception when others then
      raise warning 'push enqueue failed: %', sqlerrm;
    end;
  end;
  return null;
end $$;
create trigger enqueue_push after update on public.drawing_requests
  for each row when (old.status is distinct from new.status or old.owner_id is distinct from new.owner_id
                     or old.round is distinct from new.round or old.version is distinct from new.version)
  execute function app.enqueue_push_for_request();

-- ================================================================ 發送端（Edge Function，僅 service_role）
-- 取出到期的佇列，依員工合併為一則推播；送出前重新確認收件資格（帳號、密碼狀態、待辦仍成立）
create or replace function public.svc_push_claim(p_limit int default 50) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare rows jsonb;
begin
  -- 發送端中斷（鎖逾時未回報）且已達 5 次 → 失敗，不再無限重試
  update app.push_outbox o set status = 'FAILED', last_error = 'DISPATCH_INTERRUPTED', locked_until = null
   where o.status = 'SENDING' and o.locked_until < now() and o.attempts >= 5;
  -- 收件人已停用／需改密碼、已失去權限、或待辦類別已改變（例如第一層已轉為第二層）→ 不發送舊通知
  update app.push_outbox o set status = 'SKIPPED', last_error = 'NOT_ELIGIBLE', locked_until = null
   where o.status in ('PENDING','SENDING') and o.next_attempt_at <= now()
     and (o.locked_until is null or o.locked_until < now())
     and not exists (select 1 from public.employees e join public.drawing_requests r on r.id = o.request_id
                      where e.id = o.employee_id and e.is_active and not e.must_change_password
                        and app.pending_kind(e.id, r) = o.kind);
  -- 鎖定本批（並發的發送端以 skip locked 分流，不會重複發送同一筆）
  with due as (
    select o.id from app.push_outbox o
     where o.status in ('PENDING','SENDING') and o.next_attempt_at <= now()
       and (o.locked_until is null or o.locked_until < now())
     order by o.id limit least(greatest(coalesce(p_limit, 50), 1), 500)
     for update skip locked
  ), locked as (
    update app.push_outbox o set status = 'SENDING', attempts = o.attempts + 1, locked_until = now() + interval '2 minutes'
      from due where o.id = due.id
    returning o.id, o.employee_id, o.request_id, o.kind
  ), grouped as (
    select l.employee_id, array_agg(l.id order by l.id) as ids, count(*)::int as n,
           (array_agg(l.request_id order by l.id desc))[1] as latest_request,
           (array_agg(l.kind order by l.id desc))[1] as latest_kind
      from locked l group by l.employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'employee_id', g.employee_id, 'outbox_ids', to_jsonb(g.ids), 'count', g.n,
      'request_id', g.latest_request, 'kind', g.latest_kind,
      'badge', (app.badge_counts(g.employee_id)->>'total')::int,
      'subscriptions', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                          from app.push_subscriptions s
                         where s.employee_id = g.employee_id and s.revoked_at is null
                           and exists (select 1 from auth.sessions a join public.employees e on e.auth_user_id = a.user_id
                                        where a.id = s.session_id and e.id = s.employee_id
                                          and (a.not_after is null or now() < a.not_after))), '[]'::jsonb))), '[]'::jsonb)
    into rows from grouped g;
  return rows;
end $$;

-- 回報一位員工本批的發送結果
-- p_results：[{subscription_id, http_status, accepted, gone, error}]
--   accepted：推播服務已接受（2xx），不代表裝置已收到
--   gone：404／410 → 訂閱已失效，停用
create or replace function public.svc_push_report(p_outbox_ids bigint[], p_results jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare n_ok int; n_fail int; n_retry int; att int; final text;
begin
  insert into app.push_deliveries (outbox_ids, subscription_id, http_status, accepted, error)
  select p_outbox_ids, (x->>'subscription_id')::uuid, (x->>'http_status')::int, coalesce((x->>'accepted')::boolean, false),
         left(x->>'error', 200)
    from jsonb_array_elements(coalesce(p_results, '[]')) x
   where exists (select 1 from app.push_subscriptions s where s.id = (x->>'subscription_id')::uuid);

  update app.push_subscriptions s set last_success_at = now(), last_status = (x->>'http_status')::int, failure_count = 0
    from jsonb_array_elements(coalesce(p_results, '[]')) x
   where s.id = (x->>'subscription_id')::uuid and coalesce((x->>'accepted')::boolean, false);
  update app.push_subscriptions s set last_failure_at = now(), last_status = (x->>'http_status')::int,
         failure_count = s.failure_count + 1,
         revoked_at = case when coalesce((x->>'gone')::boolean, false) or s.failure_count + 1 >= 10 then now() else s.revoked_at end,
         revoke_reason = case when coalesce((x->>'gone')::boolean, false) then 'EXPIRED'
                              when s.failure_count + 1 >= 10 then 'TOO_MANY_FAILURES' else s.revoke_reason end
    from jsonb_array_elements(coalesce(p_results, '[]')) x
   where s.id = (x->>'subscription_id')::uuid and not coalesce((x->>'accepted')::boolean, false);

  select count(*) filter (where coalesce((x->>'accepted')::boolean, false)),
         count(*) filter (where not coalesce((x->>'accepted')::boolean, false)),
         count(*) filter (where not coalesce((x->>'accepted')::boolean, false) and not coalesce((x->>'gone')::boolean, false)
                            and coalesce((x->>'http_status')::int, 0) not in (400, 401, 403, 413))
    into n_ok, n_fail, n_retry from jsonb_array_elements(coalesce(p_results, '[]')) x;
  select max(attempts) into att from app.push_outbox where id = any(p_outbox_ids);

  final := case when jsonb_array_length(coalesce(p_results, '[]')) = 0 then 'SKIPPED'
                when n_ok > 0 then 'SENT'
                when n_retry > 0 and att < 5 then 'PENDING'
                else 'FAILED' end;
  update app.push_outbox set status = final, locked_until = null,
         sent_at = case when final = 'SENT' then now() else sent_at end,
         accepted_count = n_ok, failed_count = n_fail,
         last_error = case final when 'SKIPPED' then 'NO_SUBSCRIPTION' when 'SENT' then null
                         else left((select string_agg(distinct coalesce(x->>'http_status', x->>'error', '?'), ',')
                                      from jsonb_array_elements(p_results) x where not coalesce((x->>'accepted')::boolean, false)), 200) end,
         next_attempt_at = case when final = 'PENDING' then now() + (interval '1 minute' * power(4, least(att, 4) - 1)) else next_attempt_at end
   where id = any(p_outbox_ids);
  return jsonb_build_object('status', final, 'accepted', n_ok, 'failed', n_fail);
end $$;

-- 管理員：查詢推播發送摘要（不含 endpoint、金鑰、通知內容）
create or replace function public.admin_push_summary(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_role('SYS_ADMIN');
  return jsonb_build_object(
    'subscriptions', (select jsonb_build_object('active', count(*) filter (where revoked_at is null),
                        'revoked', count(*) filter (where revoked_at is not null)) from app.push_subscriptions),
    'outbox', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                 from (select status, count(*) n from app.push_outbox group by status) s),
    'enqueue_errors', (select count(*) from app.push_enqueue_errors),
    'recent', coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
        select jsonb_build_object('id', o.id, 'employee', e.employee_no || ' ' || e.name, 'request_no', r.request_no,
          'kind', o.kind, 'status', o.status, 'attempts', o.attempts, 'accepted', o.accepted_count, 'failed', o.failed_count,
          'last_error', o.last_error, 'created_at', o.created_at, 'sent_at', o.sent_at) x
          from app.push_outbox o join public.employees e on e.id = o.employee_id join public.drawing_requests r on r.id = o.request_id
         order by o.id desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) t), '[]'::jsonb));
end $$;

-- ================================================================ 權限
revoke all on function app.pending_kind(uuid, public.drawing_requests) from public, anon, authenticated;
revoke all on function app.badge_counts(uuid) from public, anon, authenticated;
revoke all on function app.push_endpoint_allowed(text) from public, anon, authenticated;
revoke all on function app.revoke_employee_push() from public, anon, authenticated;
revoke all on function app.enqueue_push_for_request() from public, anon, authenticated;

revoke all on function public.my_badge_summary() from public, anon;
grant execute on function public.my_badge_summary() to authenticated;
revoke all on function public.push_register(text, text, text, text) from public, anon;
grant execute on function public.push_register(text, text, text, text) to authenticated;
revoke all on function public.push_unregister(text) from public, anon;
grant execute on function public.push_unregister(text) to authenticated;
revoke all on function public.push_status(text) from public, anon;
grant execute on function public.push_status(text) to authenticated;
revoke all on function public.admin_push_summary(int) from public, anon;
grant execute on function public.admin_push_summary(int) to authenticated;

revoke all on function public.svc_push_claim(int) from public, anon, authenticated;
grant execute on function public.svc_push_claim(int) to service_role;
revoke all on function public.svc_push_report(bigint[], jsonb) from public, anon, authenticated;
grant execute on function public.svc_push_report(bigint[], jsonb) to service_role;
