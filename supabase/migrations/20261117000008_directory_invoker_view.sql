-- SUCOOT V5.7 | 0008 員工通訊錄改為 security_invoker view（避免 Security Advisor 0010 security_definer_view）
-- 讀取權限改由 app schema（不對外公開）中的 SECURITY DEFINER 函式提供；欄位與行為與 0007 相同。

create or replace function app.employee_directory()
returns table (id uuid, employee_no text, name text, department_id uuid, is_active boolean)
language sql stable security definer set search_path = '' as $$
  select e.id, e.employee_no, e.name, e.department_id, e.is_active
    from public.employees e
   where app.current_employee_id() is not null
$$;
revoke execute on function app.employee_directory() from public, anon;
grant execute on function app.employee_directory() to authenticated;

create or replace view public.v_employee_directory with (security_invoker = true) as
select * from app.employee_directory();
revoke all on public.v_employee_directory from anon, public;
grant select on public.v_employee_directory to authenticated;
