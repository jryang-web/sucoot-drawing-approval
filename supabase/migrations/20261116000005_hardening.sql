-- SUCOOT V5.7 | 0005 權限收斂：anon 不可執行任何 public/app 函式；固定 search_path
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;

alter function public.calc_receipt_due(date) set search_path = '';
alter function public.calc_is_overdue(date, public.request_status, date) set search_path = '';
alter function app.forbid_change() set search_path = '';
alter function app.err(text, text) set search_path = '';
alter function app.review_records_guard() set search_path = '';
alter function app.today_tpe() set search_path = '';
alter function app.add_business_days(date, int) set search_path = '';
alter function app.is_receipt_overdue(date, public.request_status, date) set search_path = '';
alter function app.expect_status(public.drawing_requests, public.request_status[]) set search_path = '';
alter function app.require_text(text, text) set search_path = '';

-- 往後由 postgres 建立的函式預設不開放給 anon
alter default privileges for role postgres in schema public revoke execute on functions from anon, public;
