-- SUCOOT V5.7 | 0002 管理者 RPC（部門、角色、管轄）與 Edge Function 專用的 svc_* 函式

-- ---------------------------------------------------------------- 目前使用者
create or replace function public.me() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null then perform app.err('UNAUTHENTICATED', '尚未登入'); end if;
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

-- ---------------------------------------------------------------- 部門
create or replace function public.admin_upsert_department(p_id uuid, p_code text, p_name text,
                                                          p_is_active boolean, p_reason text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := app.require_role('SYS_ADMIN'); v_before jsonb; v_id uuid;
begin
  if p_id is null then
    insert into public.departments (code, name, is_active)
    values (btrim(p_code), btrim(p_name), coalesce(p_is_active, true)) returning id into v_id;
    perform app.audit(v_admin, 'DEPARTMENT_CREATE', 'department', v_id::text, null,
                      jsonb_build_object('code', p_code, 'name', p_name), p_reason);
    return v_id;
  end if;

  select to_jsonb(d) into v_before from public.departments d where d.id = p_id for update;
  if v_before is null then perform app.err('NOT_FOUND', '部門不存在'); end if;
  if lower(v_before->>'code') <> lower(btrim(p_code)) then
    perform app.err('IMMUTABLE', '部門代碼建立後不可修改');
  end if;
  if (v_before->>'is_active')::boolean and not coalesce(p_is_active, true) then
    if exists (select 1 from public.employees e where e.department_id = p_id and e.is_active) then
      perform app.err('DEPARTMENT_IN_USE', '部門仍有啟用中的員工，不可停用');
    end if;
  end if;
  update public.departments set name = btrim(p_name), is_active = coalesce(p_is_active, true), updated_at = now()
   where id = p_id;
  perform app.audit(v_admin, 'DEPARTMENT_UPDATE', 'department', p_id::text, v_before,
                    (select to_jsonb(d) from public.departments d where d.id = p_id), p_reason);
  return p_id;
end $$;

-- ---------------------------------------------------------------- 員工基本資料（帳號建立走 Edge Function）
create or replace function public.admin_update_employee(p_employee_id uuid, p_name text, p_department_id uuid,
                                                        p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := app.require_role('SYS_ADMIN'); v_before jsonb;
begin
  perform 1 from public.employees where id = p_employee_id for update;
  if not found then perform app.err('NOT_FOUND', '員工不存在'); end if;
  if not exists (select 1 from public.departments where id = p_department_id and is_active) then
    perform app.err('INVALID_DEPARTMENT', '部門不存在或已停用');
  end if;
  v_before := app.employee_snapshot(p_employee_id);
  update public.employees set name = btrim(p_name), department_id = p_department_id, updated_at = now()
   where id = p_employee_id;
  perform app.audit(v_admin, 'EMPLOYEE_UPDATE', 'employee', p_employee_id::text, v_before,
                    app.employee_snapshot(p_employee_id), p_reason);
end $$;

-- ---------------------------------------------------------------- 角色（EMPLOYEE 一律保留）
create or replace function app.set_roles(p_admin uuid, p_employee_id uuid, p_roles public.app_role[], p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_roles public.app_role[];
begin
  perform 1 from public.employees where id = p_employee_id for update;
  if not found then perform app.err('NOT_FOUND', '員工不存在'); end if;
  if p_employee_id = p_admin and not ('SYS_ADMIN' = any(p_roles)) then
    perform app.err('FORBIDDEN', '不可移除自己的系統管理員角色');
  end if;
  v_roles := array(select distinct unnest(array_append(coalesce(p_roles, '{}'), 'EMPLOYEE'::public.app_role)));
  v_before := app.employee_snapshot(p_employee_id);

  delete from public.employee_roles where employee_id = p_employee_id and role <> all (v_roles);
  insert into public.employee_roles (employee_id, role, granted_by)
    select p_employee_id, r, p_admin from unnest(v_roles) r
    on conflict do nothing;
  if not ('DEPT_MANAGER' = any(v_roles)) then
    delete from public.manager_departments where manager_id = p_employee_id;
  end if;
  perform app.assert_admin_remains();
  perform app.audit(p_admin, 'EMPLOYEE_ROLES', 'employee', p_employee_id::text, v_before,
                    app.employee_snapshot(p_employee_id), p_reason);
end $$;

create or replace function public.admin_set_roles(p_employee_id uuid, p_roles public.app_role[], p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.set_roles(app.require_role('SYS_ADMIN'), p_employee_id, p_roles, p_reason);
end $$;

-- ---------------------------------------------------------------- 主管管轄部門
create or replace function app.set_manager_departments(p_admin uuid, p_manager_id uuid, p_department_ids uuid[], p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_before jsonb;
begin
  perform 1 from public.employees where id = p_manager_id for update;
  if not found then perform app.err('NOT_FOUND', '員工不存在'); end if;
  if coalesce(array_length(p_department_ids, 1), 0) > 0 then
    if not app.has_role('DEPT_MANAGER', p_manager_id) then
      perform app.err('INVALID_MANAGER', '此員工不具部門主管角色或帳號已停用');
    end if;
    if exists (select 1 from unnest(p_department_ids) x
               where not exists (select 1 from public.departments d where d.id = x and d.is_active)) then
      perform app.err('INVALID_DEPARTMENT', '部門不存在或已停用');
    end if;
  end if;
  v_before := app.employee_snapshot(p_manager_id);
  delete from public.manager_departments where manager_id = p_manager_id
     and department_id <> all (coalesce(p_department_ids, '{}'));
  insert into public.manager_departments (manager_id, department_id, created_by)
    select p_manager_id, x, p_admin from unnest(coalesce(p_department_ids, '{}')) x
    on conflict do nothing;
  perform app.audit(p_admin, 'MANAGER_DEPARTMENTS', 'employee', p_manager_id::text, v_before,
                    app.employee_snapshot(p_manager_id), p_reason);
end $$;

create or replace function public.admin_set_manager_departments(p_manager_id uuid, p_department_ids uuid[], p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.set_manager_departments(app.require_role('SYS_ADMIN'), p_manager_id, p_department_ids, p_reason);
end $$;

-- ================================================================ Edge Function (service_role) 專用
-- 這些函式不開放給 authenticated；呼叫者身分由 Edge Function 以 JWT 驗證後傳入。

create or replace function public.svc_assert_admin(p_caller_auth uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid; v_must boolean;
begin
  select e.id, e.must_change_password into v_id, v_must from public.employees e
   where e.auth_user_id = p_caller_auth and e.is_active;
  if v_id is null or not app.has_role('SYS_ADMIN', v_id) then
    perform app.err('FORBIDDEN', '僅系統管理員可執行');
  end if;
  if v_must then perform app.err('PASSWORD_CHANGE_REQUIRED', '請先修改密碼'); end if;
  return v_id;
end $$;

create or replace function public.svc_check_new_employee(p_caller_auth uuid, p_employee_no text, p_department_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.svc_assert_admin(p_caller_auth);
  if p_employee_no !~ '^[A-Za-z0-9_-]{2,32}$' then
    perform app.err('INVALID_EMPLOYEE_NO', '員工編號限英數字、底線、連字號，2–32 碼');
  end if;
  if exists (select 1 from public.employees where lower(employee_no) = lower(p_employee_no)) then
    perform app.err('DUPLICATE_EMPLOYEE_NO', '員工編號已存在');
  end if;
  if not exists (select 1 from public.departments where id = p_department_id and is_active) then
    perform app.err('INVALID_DEPARTMENT', '部門不存在或已停用');
  end if;
end $$;

create or replace function public.svc_create_employee(p_caller_auth uuid, p_auth_user_id uuid, p_employee_no text,
    p_name text, p_department_id uuid, p_roles public.app_role[], p_manager_department_ids uuid[], p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.svc_assert_admin(p_caller_auth); v_id uuid;
begin
  perform public.svc_check_new_employee(p_caller_auth, p_employee_no, p_department_id);
  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password)
  values (btrim(p_employee_no), p_auth_user_id, btrim(p_name), p_department_id, true)
  returning id into v_id;
  perform app.audit(v_admin, 'EMPLOYEE_CREATE', 'employee', v_id::text, null,
                    jsonb_build_object('employee_no', p_employee_no, 'name', p_name, 'department_id', p_department_id), p_reason);
  perform app.set_roles(v_admin, v_id, coalesce(p_roles, '{}'), p_reason);
  if coalesce(array_length(p_manager_department_ids, 1), 0) > 0 then
    perform app.set_manager_departments(v_admin, v_id, p_manager_department_ids, p_reason);
  end if;
  return v_id;
end $$;

create or replace function public.svc_get_employee_auth(p_caller_auth uuid, p_employee_id uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  perform public.svc_assert_admin(p_caller_auth);
  select auth_user_id into v from public.employees where id = p_employee_id;
  if v is null then perform app.err('NOT_FOUND', '員工不存在或尚未綁定登入帳號'); end if;
  return v;
end $$;

create or replace function public.svc_after_password_reset(p_caller_auth uuid, p_employee_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.svc_assert_admin(p_caller_auth);
begin
  update public.employees set must_change_password = true, updated_at = now() where id = p_employee_id;
  perform app.audit(v_admin, 'PASSWORD_RESET', 'employee', p_employee_id::text, null, null, p_reason);
end $$;

create or replace function public.svc_set_active(p_caller_auth uuid, p_employee_id uuid, p_active boolean, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_admin uuid := public.svc_assert_admin(p_caller_auth); v_before jsonb; v_auth uuid;
begin
  if p_employee_id = v_admin and not p_active then perform app.err('FORBIDDEN', '不可停用自己的帳號'); end if;
  if p_reason is null or btrim(p_reason) = '' then perform app.err('REASON_REQUIRED', '請填寫原因'); end if;
  select auth_user_id into v_auth from public.employees where id = p_employee_id for update;
  if not found then perform app.err('NOT_FOUND', '員工不存在'); end if;
  v_before := app.employee_snapshot(p_employee_id);
  update public.employees
     set is_active = p_active, deactivated_at = case when p_active then null else now() end, updated_at = now()
   where id = p_employee_id;
  perform app.assert_admin_remains();
  perform app.audit(v_admin, case when p_active then 'EMPLOYEE_ACTIVATE' else 'EMPLOYEE_DEACTIVATE' end,
                    'employee', p_employee_id::text, v_before, app.employee_snapshot(p_employee_id), p_reason);
  return v_auth;
end $$;

create or replace function public.svc_password_changed(p_auth_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  update public.employees set must_change_password = false, updated_at = now()
   where auth_user_id = p_auth_user_id and is_active returning id into v_id;
  if v_id is null then perform app.err('ACCOUNT_INACTIVE', '帳號不存在或已停用'); end if;
  perform app.audit(v_id, 'PASSWORD_CHANGED_BY_SELF', 'employee', v_id::text, null, null, null);
end $$;

-- ---------------------------------------------------------------- 權限
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.me() to authenticated;
grant execute on function public.admin_upsert_department(uuid,text,text,boolean,text) to authenticated;
grant execute on function public.admin_update_employee(uuid,text,uuid,text) to authenticated;
grant execute on function public.admin_set_roles(uuid,public.app_role[],text) to authenticated;
grant execute on function public.admin_set_manager_departments(uuid,uuid[],text) to authenticated;
grant execute on function public.svc_assert_admin(uuid) to service_role;
grant execute on function public.svc_check_new_employee(uuid,text,uuid) to service_role;
grant execute on function public.svc_create_employee(uuid,uuid,text,text,uuid,public.app_role[],uuid[],text) to service_role;
grant execute on function public.svc_get_employee_auth(uuid,uuid) to service_role;
grant execute on function public.svc_after_password_reset(uuid,uuid,text) to service_role;
grant execute on function public.svc_set_active(uuid,uuid,boolean,text) to service_role;
grant execute on function public.svc_password_changed(uuid) to service_role;
revoke execute on function app.set_roles(uuid,uuid,public.app_role[],text) from authenticated;
revoke execute on function app.set_manager_departments(uuid,uuid,uuid[],text) from authenticated;
