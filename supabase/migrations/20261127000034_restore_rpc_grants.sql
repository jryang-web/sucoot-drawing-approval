-- SUCOOT V5.9.1 修正：恢復被移除的 RPC 執行權限（與 repo migration 定義一致）
-- 正式環境上述函式的 authenticated EXECUTE 權限在 migration 紀錄之外被移除，導致管理員設定角色、
-- 部門主管管轄、員工資料、部門維護、代理、認領重新指派，以及員工取消申請時出現「權限不足」。
-- 這些函式皆為 SECURITY DEFINER＋search_path=''，並於函式內驗證身分：
--   admin_set_roles／admin_set_manager_departments／admin_update_employee／admin_upsert_department／
--   admin_revoke_delegation／admin_release_claim：app.require_role('SYS_ADMIN')
--   admin_create_delegation：只能建立本人（被代理人）的代理
--   cancel_request：只能取消本人申請
-- 只授予 authenticated（登入員工），不授予 anon。
grant execute on function public.admin_set_roles(uuid, public.app_role[], text) to authenticated;
grant execute on function public.admin_set_manager_departments(uuid, uuid[], text) to authenticated;
grant execute on function public.admin_update_employee(uuid, text, uuid, text) to authenticated;
grant execute on function public.admin_upsert_department(uuid, text, text, boolean, text) to authenticated;
grant execute on function public.admin_create_delegation(uuid, uuid, smallint, date, date, text) to authenticated;
grant execute on function public.admin_revoke_delegation(uuid, text) to authenticated;
grant execute on function public.admin_release_claim(uuid, text, uuid) to authenticated;
grant execute on function public.cancel_request(uuid, text, integer) to authenticated;
