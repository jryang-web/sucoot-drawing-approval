-- SUCOOT V5.7 | 0007 員工資料最小公開
-- 一般員工只能看到同事的「編號、姓名、部門、是否啟用」（v_employee_directory）。
-- employees／employee_roles／manager_departments 完整資料只開放本人與系統管理員。

-- 員工通訊錄：以 view 擁有者權限執行（不受 employees RLS 限制），只輸出非敏感欄位，且僅限啟用中的登入員工查詢
create view public.v_employee_directory with (security_invoker = false) as
select e.id, e.employee_no, e.name, e.department_id, e.is_active
  from public.employees e
 where app.current_employee_id() is not null;
revoke all on public.v_employee_directory from anon, public;
grant select on public.v_employee_directory to authenticated;

-- 完整資料：本人或系統管理員
drop policy employees_select on public.employees;
create policy employees_select on public.employees for select to authenticated
  using (id = app.current_employee_id() or app.has_role('SYS_ADMIN'));

drop policy employee_roles_select on public.employee_roles;
create policy employee_roles_select on public.employee_roles for select to authenticated
  using (employee_id = app.current_employee_id() or app.has_role('SYS_ADMIN'));

drop policy manager_departments_select on public.manager_departments;
create policy manager_departments_select on public.manager_departments for select to authenticated
  using (manager_id = app.current_employee_id() or app.has_role('SYS_ADMIN'));

-- 案件清單 view 改用通訊錄取得申請人／負責人姓名（審核者、圖管人員看他人案件時仍可顯示姓名）
create or replace view public.v_requests with (security_invoker = true) as
select r.*,
       app.is_receipt_overdue(r.receipt_due_date, r.status, app.today_tpe()) as is_receipt_overdue,
       a.employee_no as applicant_no, a.name as applicant_name,
       o.employee_no as owner_no, o.name as owner_name,
       d.name as department_name,
       (select count(*) from public.drawing_request_items i where i.request_id = r.id) as item_count,
       (select bool_or(i.is_urgent) from public.drawing_request_items i where i.request_id = r.id) as is_urgent,
       (select c.staff_id from public.issue_claims c where c.request_id = r.id and c.released_at is null) as claimed_by
  from public.drawing_requests r
  join public.v_employee_directory a on a.id = r.applicant_id
  join public.v_employee_directory o on o.id = r.owner_id
  join public.departments d on d.id = r.department_id;
revoke all on public.v_requests from anon;
grant select on public.v_requests to authenticated;
