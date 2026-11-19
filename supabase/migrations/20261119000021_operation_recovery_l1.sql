alter table app.business_operations add column closed_at timestamptz;

-- A disable closes the inbox independently of whether a result was ever displayed.
create function app.close_disabled_employee_inbox() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  update app.business_operations set closed_at=now()
    where actor=new.id and closed_at is null;
  return new;
end $$;
revoke all on function app.close_disabled_employee_inbox() from public,anon,authenticated;
create trigger close_inbox_on_disable after update of is_active on public.employees
for each row when(old.is_active and not new.is_active) execute function app.close_disabled_employee_inbox();

update app.business_operations b set closed_at=d.disabled_at
from (select target_id,max(created_at) disabled_at from public.admin_audit_logs
      where target_type='employee' and action='EMPLOYEE_DEACTIVATE' group by target_id) d
where b.actor::text=d.target_id and b.created_at<=d.disabled_at;

-- An old device marker can predate prepare_operation. Reserve its key atomically
-- so a delayed prepare can never execute after recovery reports it unsubmitted.
create function public.retire_missing_operation(p_key uuid) returns void
language plpgsql security definer set search_path='' as $$
declare employee uuid:=app.require_employee();
begin
  insert into app.business_operations(id,actor,action,args,result,closed_at)
    values(p_key,employee,'not_received','{}','{"ok":false,"error":"未送達"}',now())
    on conflict(id) do nothing;
end $$;
revoke all on function public.retire_missing_operation(uuid) from public,anon;
grant execute on function public.retire_missing_operation(uuid) to authenticated;

create or replace function public.operation_results(p_keys uuid[] default '{}')
returns table(id uuid,action text,case_id text,result jsonb) language sql security definer set search_path='' as $$
 select b.id,case when b.action='case_exception' and b.args->>'p_withdraw'='true' then 'withdraw_exception'
                  when b.action='submit_request' and b.args->>'p_resubmit_note' is not null then 'resubmit'
                  else b.action end,
        r.request_no,b.result
 from app.business_operations b left join public.drawing_requests r
   on r.id::text=coalesce(b.result->>'id',b.args->>'p_id')
   and app.can_view_request(r.id,r.applicant_id,r.owner_id,r.department_id,r.status)
 where b.actor=app.require_employee() and b.closed_at is null and (b.shown_at is null or b.id=any(p_keys))
 order by b.created_at,b.id
$$;

create view public.v_l1_queue with (security_invoker=true) as
select r.* from public.v_requests r where r.status='PENDING_DEPT_REVIEW'
and r.department_id in (select public.my_l1_departments());
revoke all on public.v_l1_queue from public,anon;
grant select on public.v_l1_queue to authenticated;
