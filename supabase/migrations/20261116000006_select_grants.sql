-- SUCOOT V5.7 | 0006 本專案不會自動授予 API 角色資料表權限：明確授予 authenticated「只讀」，列層級由 RLS 控制
grant usage on schema public to authenticated;
grant select on public.departments, public.employees, public.employee_roles, public.manager_departments,
                public.admin_audit_logs, public.drawing_requests, public.drawing_request_items, public.request_revisions,
                public.review_delegations, public.review_records, public.request_status_history, public.issue_claims,
                public.item_abnormal_reports, public.issue_records, public.receipt_records, public.ownership_transfers
  to authenticated;
-- anon 一律無權限
revoke all on all tables in schema public from anon;
