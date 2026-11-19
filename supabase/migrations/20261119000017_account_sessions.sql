-- Supabase Auth's signed session_id identifies the device session; deleting the
-- session also deletes its refresh tokens. Already-issued JWTs need this DB check.
create function app.session_alive() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.sessions s where s.id=(auth.jwt()->>'session_id')::uuid
   and s.user_id=auth.uid() and (s.not_after is null or now()<s.not_after))
$$;
revoke all on function app.session_alive() from public,anon,authenticated;

create or replace function app.current_employee_id() returns uuid
language sql stable security definer set search_path='' as $$
 select id from public.employees where auth_user_id=auth.uid() and is_active and app.session_alive()
$$;

create function app.require_live_employee() returns public.employees
language plpgsql volatile security definer set search_path='' as $$
declare emp public.employees;
begin
  if current_setting('transaction_read_only')='on' then
    select * into emp from public.employees where auth_user_id=auth.uid();
  else
    -- Hold the same employee row until the business transaction commits.
    select * into emp from public.employees where auth_user_id=auth.uid() for share;
  end if;
  if emp.id is null or not emp.is_active then perform app.err('ACCOUNT_INACTIVE','帳號不存在或已停用'); end if;
  if not app.session_alive() then perform app.err('SESSION_REVOKED','登入已失效，請重新登入'); end if;
  return emp;
end $$;
revoke all on function app.require_live_employee() from public,anon,authenticated;

create or replace function app.require_employee() returns uuid
language plpgsql volatile security definer set search_path='' as $$
declare emp public.employees:=app.require_live_employee();
begin
  if emp.must_change_password then perform app.err('PASSWORD_CHANGE_REQUIRED','請先修改臨時密碼'); end if;
  return emp.id;
end $$;

-- Serialize password rotation, audit and revocation in a single transaction.
-- The digest is compatible with the bcrypt credentials used by this Auth project.
create function app.rotate_employee_password(emp public.employees, secret text, force_change boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  update auth.users set encrypted_password=extensions.crypt(secret,extensions.gen_salt('bf',10)),
    recovery_token='', recovery_sent_at=null, updated_at=now() where id=emp.auth_user_id;
  if not found then perform app.err('NOT_FOUND','找不到員工登入帳號'); end if;
  update public.employees set must_change_password=force_change, updated_at=now() where id=emp.id;
  delete from auth.sessions where user_id=emp.auth_user_id;
end $$;
revoke all on function app.rotate_employee_password(public.employees,text,boolean) from public,anon,authenticated;

create function public.change_employee_password(p_current text,p_new text,p_confirmation text) returns jsonb
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
  perform app.audit(emp.id,'PASSWORD_CHANGED_BY_SELF','employee',emp.id::text,null,null,null);
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.manage_employee_login(p_employee uuid,p_action text,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app.require_role('SYS_ADMIN'); emp public.employees; secret text;
begin
  perform app.require_text(p_reason,'原因');
  if not(case p_action
    when 'reset' then p_reason in ('忘記密碼','臨時密碼遺失','資安需求','管理員要求')
    when 'activate' then p_reason in ('復職','職務調整完成','資安問題解除')
    when 'deactivate' then p_reason in ('離職','職務異動','資安風險','暫停使用')
    else false end or (left(p_reason,3)='其他：' and btrim(substr(p_reason,4))<>''))
    then perform app.err('INVALID_INPUT','請選擇有效原因，其他原因須填說明'); end if;
  if p_employee=actor then perform app.err('FORBIDDEN','不可在後台重設或停用自己的帳號'); end if;
  select * into emp from public.employees where id=p_employee for update;
  if not found then perform app.err('NOT_FOUND','員工不存在'); end if;
  if p_action='reset' then
    secret:=encode(extensions.gen_random_bytes(16),'hex');
    perform app.rotate_employee_password(emp,secret,true);
    perform app.audit(actor,'PASSWORD_RESET','employee',emp.id::text,null,null,p_reason);
  elsif p_action in ('activate','deactivate') then
    if emp.is_active=(p_action='activate') then perform app.err('INVALID_STATE','帳號狀態已變更'); end if;
    perform public.svc_set_active(auth.uid(),emp.id,p_action='activate',p_reason);
    update auth.users set banned_until=case when p_action='deactivate' then now()+interval '100 years' end
      where id=emp.auth_user_id;
    if p_action='activate' then
      secret:=encode(extensions.gen_random_bytes(16),'hex');
      perform app.rotate_employee_password(emp,secret,true);
    else
      delete from auth.sessions where user_id=emp.auth_user_id;
    end if;
  else perform app.err('INVALID_INPUT','未知的帳號操作');
  end if;
  return jsonb_strip_nulls(jsonb_build_object('ok',true,'new_password',secret));
end $$;

-- Employee passwords must pass the current-password and confirmation checks.
-- Auth still owns registration, sign-in and token refresh.
create function app.guard_employee_password() returns trigger
language plpgsql set search_path='' as $$
begin
  if current_user='supabase_auth_admin' and exists(select 1 from auth.users where id=new.id)
    then raise exception '請使用員工密碼變更流程'; end if;
  return new;
end $$;
create trigger sucoot_password_path before update of encrypted_password on auth.users
for each row when(old.encrypted_password is distinct from new.encrypted_password)
execute function app.guard_employee_password();
revoke all on function app.guard_employee_password() from public,anon,authenticated;
revoke all on function public.change_employee_password(text,text,text),public.manage_employee_login(uuid,text,text) from public,anon;
grant execute on function public.change_employee_password(text,text,text),public.manage_employee_login(uuid,text,text) to authenticated;

create or replace function public.me() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null then perform app.err('UNAUTHENTICATED', '尚未登入'); end if;
  if not app.session_alive() then perform app.err('SESSION_REVOKED','登入已失效，請重新登入'); end if;
  select jsonb_build_object(
      'id', e.id, 'employee_no', e.employee_no, 'name', e.name,
      'department_id', e.department_id, 'department_name', d.name,
      'is_active', e.is_active, 'must_change_password', e.must_change_password,
      'roles', coalesce((select jsonb_agg(r.role order by r.role) from public.employee_roles r where r.employee_id = e.id), '[]'),
      'manager_departments', coalesce((select jsonb_agg(m.department_id) from public.manager_departments m where m.manager_id = e.id), '[]'))
    into v
    from public.employees e join public.departments d on d.id = e.department_id
   where e.auth_user_id = auth.uid();
  if v is null then perform app.err('ACCOUNT_INACTIVE', '此登入帳號尚未對應員工資料'); end if;
  if not (v->>'is_active')::boolean then perform app.err('ACCOUNT_INACTIVE', '帳號已停用'); end if;
  return v;
end $$;
