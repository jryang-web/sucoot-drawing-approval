create table public.exception_notices(
  id bigint generated always as identity primary key,
  request_id uuid not null references public.case_exceptions(request_id),
  recipient uuid not null references public.employees(id),
  occurred_at timestamptz not null default now(),
  read_at timestamptz,
  unique(request_id,recipient)
);
alter table public.exception_notices enable row level security;
revoke all on public.exception_notices from public,anon,authenticated;
grant select on public.exception_notices to authenticated;
create policy own_admin_inbox on public.exception_notices for select to authenticated
 using(app.has_role('SYS_ADMIN') and recipient=app.current_employee_id() and occurred_at>=now()-interval '30 days');

create function app.notify_case_admins() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.exception_notices(request_id,recipient)
    select new.request_id,e.id from public.employees e join public.employee_roles r on r.employee_id=e.id
    where e.is_active and r.role='SYS_ADMIN';
  return new;
end $$;
revoke all on function app.notify_case_admins() from public,anon,authenticated;
create trigger exception_reported after insert on public.case_exceptions
for each row execute function app.notify_case_admins();

create function public.read_exception_notice(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=app.require_role('SYS_ADMIN');
begin
  update public.exception_notices set read_at=coalesce(read_at,now())
   where id=p_id and recipient=actor and occurred_at>=now()-interval '30 days';
end $$;

create function public.admin_exception_note(p_id uuid,p_kind text,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app.require_role('SYS_ADMIN'); r public.drawing_requests;
begin
  r:=app.lock_request(p_id,null);
  if r.status <> 'ISSUE_ABNORMAL' or not exists(select 1 from public.case_exceptions where request_id=p_id)
    then perform app.err('INVALID_STATE','本案沒有待處理整案異常'); end if;
  perform app.require_text(p_note,'補充說明');
  if length(btrim(p_note))>500 or p_kind is null or p_kind not in ('補充資訊','資料更正說明','處理結果說明','其他')
    then perform app.err('INVALID_INPUT','分類或說明長度不符'); end if;
  perform app.audit(actor,'EXCEPTION_NOTE','drawing_request',p_id::text,null,jsonb_build_object('category',p_kind),btrim(p_note));
end $$;
revoke all on function public.read_exception_notice(bigint),public.admin_exception_note(uuid,text,text) from public,anon;
grant execute on function public.read_exception_notice(bigint),public.admin_exception_note(uuid,text,text) to authenticated;

create or replace function public.admin_alerts() returns table (request_id uuid, request_no text, status public.request_status, problem text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_role('SYS_ADMIN');
  return query
  select r.id, r.request_no, r.status, '此部門沒有可審核的第一層主管'::text
    from public.drawing_requests r
   where r.status = 'PENDING_DEPT_REVIEW'
     and not exists (select 1 from public.employees e where e.is_active and (app.l1_authority(e.id, r.department_id)).ok)
  union all
  select r.id, r.request_no, r.status, '沒有可執行第二層審核的圖管主管（須與第一層不同人）'::text
    from public.drawing_requests r
   where r.status = 'PENDING_DRAWING_REVIEW'
     and not exists (select 1 from public.employee_roles er join public.employees e on e.id = er.employee_id
                     where er.role = 'DRAWING_MANAGER' and e.is_active
                       and e.id <> (select rr.reviewer_id from public.review_records rr where rr.request_id = r.id
                                     and rr.round = r.round and rr.level = 1 and rr.is_effective))
  union all
  select r.id, r.request_no, r.status, '沒有啟用中的圖管人員或認領人已停用'::text
    from public.drawing_requests r
   where r.status = 'PENDING_ISSUE'
     and (not exists (select 1 from public.employee_roles er join public.employees e on e.id = er.employee_id
                      where er.role = 'DRAWING_STAFF' and e.is_active)
          or exists (select 1 from public.issue_claims c join public.employees e on e.id = c.staff_id
                     where c.request_id = r.id and c.released_at is null and not e.is_active))
  union all
  select r.id, r.request_no, r.status, '案件負責人帳號已停用，請管理員檢視案件'::text
    from public.drawing_requests r join public.employees e on e.id = r.owner_id
   where not e.is_active and r.status not in ('COMPLETED','REJECTED','CANCELLED');
end $$;
-- Historical reports remain available to authorised administrators.
alter policy item_abnormal_reports_select on public.item_abnormal_reports using (app.has_role('SYS_ADMIN'));

create function app.revoke_disabled_delegations() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.review_delegations set revoked_at=now(),revoked_by=app.current_employee_id(),revoke_reason='帳號停用'
    where revoked_at is null and (principal_id=new.id or delegate_id=new.id) and valid_to>=app.today_tpe();
  return new;
end $$;
revoke all on function app.revoke_disabled_delegations() from public,anon,authenticated;
create trigger disable_delegations after update of is_active on public.employees
for each row when(old.is_active and not new.is_active) execute function app.revoke_disabled_delegations();
