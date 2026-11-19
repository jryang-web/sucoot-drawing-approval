create table app.personal_security_notices (
  audit_id bigint primary key references public.admin_audit_logs(id),
  employee_id uuid not null references public.employees(id),
  event text not null check (event in ('initial','change','reset','activate')),
  occurred_at timestamptz not null,
  read_at timestamptz
);
create index personal_security_notices_employee_time on app.personal_security_notices(employee_id, occurred_at desc, audit_id desc);
alter table app.personal_security_notices enable row level security;
revoke all on app.personal_security_notices from public, anon, authenticated;

create function app.record_personal_security_notice() returns trigger
language plpgsql security definer set search_path='' as $$
declare kind text;
begin
  if new.action='PASSWORD_CHANGED_BY_SELF' then
    if new.before->>'must_change_password'='true' then
      -- Only the original temporary password produces a first-setup notice.
      if exists(select 1 from public.admin_audit_logs where target_type='employee'
        and target_id=new.target_id and action in ('PASSWORD_RESET','EMPLOYEE_ACTIVATE','PASSWORD_CHANGED_BY_SELF')
        and id<new.id) then return new; end if;
      kind:='initial';
    else
      kind:='change';
    end if;
  elsif new.action='PASSWORD_RESET' then kind:='reset';
  else kind:='activate';
  end if;
  insert into app.personal_security_notices(audit_id,employee_id,event,occurred_at)
  values(new.id,new.target_id::uuid,kind,new.created_at) on conflict(audit_id) do nothing;
  return new;
end $$;
revoke all on function app.record_personal_security_notice() from public,anon,authenticated;
create trigger personal_security_notice after insert on public.admin_audit_logs for each row
when (new.target_type='employee' and new.action in ('PASSWORD_CHANGED_BY_SELF','PASSWORD_RESET','EMPLOYEE_ACTIVATE'))
execute function app.record_personal_security_notice();

create or replace function public.change_employee_password(p_current text,p_new text,p_confirmation text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare emp public.employees; digest text;
begin
  select * into emp from public.employees where auth_user_id=auth.uid() for update;
  perform app.require_live_employee();
  if p_new is null or length(p_new)<8 then perform app.err('WEAK_PASSWORD','個人密碼至少 8 碼'); end if;
  if p_new is distinct from p_confirmation then perform app.err('INVALID_INPUT','兩次新密碼不一致'); end if;
  select encrypted_password into digest from auth.users where id=emp.auth_user_id for update;
  if p_current is null or digest is null or extensions.crypt(p_current,digest) is distinct from digest then
    perform app.err('WRONG_PASSWORD','目前密碼不正確');
  end if;
  if emp.must_change_password and extensions.crypt(p_new,digest)=digest then
    perform app.err('WEAK_PASSWORD','新密碼不可與臨時密碼相同');
  end if;
  perform app.rotate_employee_password(emp,p_new,false);
  perform app.audit(emp.id,'PASSWORD_CHANGED_BY_SELF','employee',emp.id::text,jsonb_build_object('must_change_password',emp.must_change_password),null,null);
  return jsonb_build_object('ok',true);
end $$;

create function public.my_security_notices() returns table(id text,event text,occurred_at timestamptz,read_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare employee uuid:=app.require_employee();
begin
  return query select n.audit_id::text,n.event,n.occurred_at,n.read_at from app.personal_security_notices n
    where n.employee_id=employee and n.occurred_at>=now()-interval '30 days'
    order by n.occurred_at desc,n.audit_id desc;
end $$;

create function public.read_security_notice(p_id bigint) returns timestamptz
language plpgsql security definer set search_path='' as $$
declare employee uuid:=app.require_employee(); seen timestamptz;
begin
  update app.personal_security_notices set read_at=coalesce(read_at,now())
    where audit_id=p_id and employee_id=employee and occurred_at>=now()-interval '30 days'
    returning read_at into seen;
  return seen;
end $$;
revoke all on function public.my_security_notices(),public.read_security_notice(bigint) from public,anon;
grant execute on function public.my_security_notices(),public.read_security_notice(bigint) to authenticated;
