-- SUCOOT V5.9.2 | 案件結果通知（駁回、強制結案、取消、簽收完成）＋推播
-- 使用者決策（2026-11-27）：
--   駁回           → 申請人、負責人
--   管理員強制結案 → 申請人、負責人
--   申請人取消     → 原本待審的主管（含有效代理人）
--   簽收完成       → 發行該案的圖管人員
--   推播內容不顯示案件編號，只顯示通知類別摘要；App 內通知中心（已讀／未讀、最近 30 天）可查看案件編號。
-- 原則：
--   * 不修改既有業務 RPC；由 drawing_requests 狀態變更觸發器產生，失敗不回滾業務交易（與待辦推播相同）。
--   * 操作者本人不收到自己操作的通知；同一事件同一人只產生一次。
--   * 角標＝未讀安全通知＋未讀案件通知＋待辦案件。
--   * 所有 UPDATE／DELETE 皆含 WHERE（正式環境 safeupdate）。

-- ================================================================ 案件通知（通知中心）
create table app.case_notices (
  id          bigserial primary key,
  employee_id uuid not null references public.employees(id),
  request_id  uuid not null references public.drawing_requests(id),
  kind        text not null check (kind in ('R_REJECTED','R_FORCE_CLOSED','R_CANCELLED','R_RECEIPT_DONE')),
  dedupe_key  text not null unique,
  occurred_at timestamptz not null default now(),
  read_at     timestamptz
);
create index case_notices_employee_idx on app.case_notices (employee_id, occurred_at desc);
alter table app.case_notices enable row level security;
revoke all on app.case_notices from public, anon, authenticated;

-- 結果事件的收件人（不含操作者）；不是結果事件回傳空集合
create or replace function app.result_recipients(o public.drawing_requests, n public.drawing_requests)
returns table (employee_id uuid, kind text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if o.status is not distinct from n.status then return; end if;
  if n.status = 'REJECTED' then
    return query select x, 'R_REJECTED' from unnest(array[n.applicant_id, n.owner_id]) x group by x;
  elsif n.status = 'CANCELLED' then
    -- 原本待審的主管：取消前對此案件有待辦（第一層待審，含有效代理）的人
    return query select e.id, 'R_CANCELLED' from public.employees e
      where e.is_active and app.pending_kind(e.id, o) in ('L1', 'L2');
  elsif n.status = 'COMPLETED' then
    if exists (select 1 from public.receipt_records rr where rr.request_id = n.id and rr.kind = 'FULL') then
      -- 整案簽收完成 → 發行該案的圖管人員
      return query select ir.issued_by, 'R_RECEIPT_DONE' from public.issue_records ir
        where ir.request_id = n.id group by ir.issued_by;
    else
      -- 管理員強制結案 → 申請人、負責人
      return query select x, 'R_FORCE_CLOSED' from unnest(array[n.applicant_id, n.owner_id]) x group by x;
    end if;
  end if;
end $$;

-- ================================================================ 佇列觸發器（取代 032 版本：加入結果通知）
create or replace function app.enqueue_push_for_request() returns trigger
language plpgsql security definer set search_path = '' as $$
declare actor uuid; claim uuid; sig text;
begin
  begin
    actor := app.current_employee_id();
    -- 待辦通知（032）
    select c.id into claim from public.issue_claims c where c.request_id = new.id and c.released_at is null;
    sig := new.id || ':' || new.status || ':' || new.round || ':' || new.owner_id || ':' || coalesce(claim::text, '-');
    insert into app.push_outbox (employee_id, request_id, kind, dedupe_key)
    select e.id, new.id, k.kind, sig || ':' || e.id
      from public.employees e
      cross join lateral (select app.pending_kind(e.id, new) as kind) k
     where e.is_active and k.kind is not null and e.id is distinct from actor
    on conflict (dedupe_key) do nothing;

    -- 結果通知（035）：通知中心＋推播
    insert into app.case_notices (employee_id, request_id, kind, dedupe_key)
    select r.employee_id, new.id, r.kind, 'res:' || new.id || ':' || new.status || ':' || new.round || ':' || r.employee_id
      from app.result_recipients(old, new) r join public.employees e on e.id = r.employee_id
     where e.is_active and r.employee_id is distinct from actor
    on conflict (dedupe_key) do nothing;
    insert into app.push_outbox (employee_id, request_id, kind, dedupe_key)
    select r.employee_id, new.id, r.kind, 'res:' || new.id || ':' || new.status || ':' || new.round || ':' || r.employee_id
      from app.result_recipients(old, new) r join public.employees e on e.id = r.employee_id
     where e.is_active and r.employee_id is distinct from actor
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

-- ================================================================ 角標計數（取代 032 版本：加入未讀案件通知）
create or replace function app.badge_counts(p_emp uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with pending as (
    select app.pending_kind(p_emp, r) as kind
      from public.drawing_requests r
     where r.status in ('RETURNED','PENDING_DEPT_REVIEW','PENDING_DRAWING_REVIEW','PENDING_ISSUE','ISSUE_ABNORMAL','PENDING_RECEIPT')
  ), cases as (
    select kind, count(*)::int n from pending where kind is not null group by kind
  ), security as (
    select count(*)::int n from app.personal_security_notices s
     where s.employee_id = p_emp and s.read_at is null and s.occurred_at >= now() - interval '30 days'
  ), results as (
    select count(*)::int n from app.case_notices c
     where c.employee_id = p_emp and c.read_at is null and c.occurred_at >= now() - interval '30 days'
  )
  select jsonb_build_object(
    'unread_notices', (select n from security) + (select n from results),
    'unread_security_notices', (select n from security),
    'unread_case_notices', (select n from results),
    'pending_cases', coalesce((select sum(n) from cases), 0)::int,
    'total', (select n from security) + (select n from results) + coalesce((select sum(n) from cases), 0)::int,
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from cases), '{}'::jsonb),
    'as_of', now())
$$;

-- ================================================================ 員工：我的案件通知（最近 30 天）、標為已讀
create or replace function public.my_case_notices()
returns table (id bigint, kind text, request_id uuid, request_no text, occurred_at timestamptz, read_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.require_employee();
begin
  return query select c.id, c.kind, c.request_id, r.request_no, c.occurred_at, c.read_at
    from app.case_notices c join public.drawing_requests r on r.id = c.request_id
   where c.employee_id = me and c.occurred_at >= now() - interval '30 days'
   order by c.occurred_at desc, c.id desc;
end $$;

create or replace function public.read_case_notice(p_id bigint) returns timestamptz
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid := app.require_employee(); seen timestamptz;
begin
  update app.case_notices set read_at = coalesce(read_at, now())
   where id = p_id and employee_id = me and occurred_at >= now() - interval '30 days'
   returning read_at into seen;
  return seen;
end $$;

-- ================================================================ 發送端（取代 032／033 版本：結果通知的發送資格）
-- 待辦通知：須仍為同一類別待辦；結果通知：收件人帳號有效、不需改密碼即可（不要求仍有待辦）
create or replace function public.svc_push_claim(p_limit int default 50) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare rows jsonb;
begin
  update app.push_outbox o set status = 'FAILED', last_error = 'DISPATCH_INTERRUPTED', locked_until = null
   where o.status = 'SENDING' and o.locked_until < now() and o.attempts >= 5;
  update app.push_outbox o set status = 'SKIPPED', last_error = 'NOT_ELIGIBLE', locked_until = null
   where o.status in ('PENDING','SENDING') and o.next_attempt_at <= now()
     and (o.locked_until is null or o.locked_until < now())
     and not exists (select 1 from public.employees e join public.drawing_requests r on r.id = o.request_id
                      where e.id = o.employee_id and e.is_active and not e.must_change_password
                        and (o.kind like 'R\_%' or app.pending_kind(e.id, r) = o.kind));
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

-- ================================================================ 權限
revoke all on function app.result_recipients(public.drawing_requests, public.drawing_requests) from public, anon, authenticated;
revoke all on function public.my_case_notices() from public, anon;
grant execute on function public.my_case_notices() to authenticated;
revoke all on function public.read_case_notice(bigint) from public, anon;
grant execute on function public.read_case_notice(bigint) to authenticated;
revoke all on function public.svc_push_claim(int) from public, anon, authenticated;
grant execute on function public.svc_push_claim(int) to service_role;
