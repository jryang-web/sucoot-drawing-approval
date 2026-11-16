-- SUCOOT V5.7 | 0004 初始化第一位系統管理員（只在系統內尚無任何 SYS_ADMIN 時生效）
-- 前置：管理者已在 Supabase Dashboard 手動建立 Auth 帳號 admin@login.sucoot.com
do $$
declare v_auth uuid; v_dept uuid; v_emp uuid;
begin
  if exists (select 1 from public.employee_roles where role = 'SYS_ADMIN') then
    raise notice 'bootstrap skipped: SYS_ADMIN already exists';
    return;
  end if;
  select id into v_auth from auth.users where email = 'admin@login.sucoot.com';
  if v_auth is null then raise exception 'BOOTSTRAP: auth user admin@login.sucoot.com not found'; end if;

  insert into public.departments (code, name) values ('ADM', '管理部')
    on conflict do nothing;
  select id into v_dept from public.departments where lower(code) = 'adm';

  insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password)
  values ('admin', v_auth, '系統管理員', v_dept, false)   -- 密碼由管理者本人於 Dashboard 設定
  returning id into v_emp;
  insert into public.employee_roles (employee_id, role) values (v_emp, 'EMPLOYEE'), (v_emp, 'SYS_ADMIN');
  insert into public.admin_audit_logs (actor_id, action, target_type, target_id, after, reason)
  values (v_emp, 'BOOTSTRAP_ADMIN', 'employee', v_emp::text,
          jsonb_build_object('employee_no', 'admin', 'roles', array['EMPLOYEE','SYS_ADMIN'], 'department', '管理部'),
          '系統初始化：第一位系統管理員');
end $$;
