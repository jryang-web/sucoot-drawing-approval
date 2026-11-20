\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare r uuid; st public.request_status;
begin
 perform pg_temp.login('TEST001');
 foreach st in array array['DRAFT','PENDING_DEPT_REVIEW','RETURNED']::public.request_status[] loop
  r:=pg_temp.draft();
  update public.drawing_requests set status=st where id=r;
  perform public.cancel_request(r,'測試取消');
  if not exists(select from public.request_status_history where request_id=r and to_status='CANCELLED' and reason='測試取消') then raise exception 'missing cancellation'; end if;
 end loop;
end $$;
rollback;
