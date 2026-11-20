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

 r:=pg_temp.draft();
 perform public.submit_request(r);
 perform pg_temp.login('TEST003');
 perform public.review_level1(r,'APPROVE');
 perform pg_temp.login('TEST004');
 perform public.review_level2(r,'RETURN','需要補件');
 perform pg_temp.login('TEST001');
 perform public.cancel_request(r,'二審退回後取消');
 if not exists(select from public.request_status_history where request_id=r and from_status='RETURNED'
               and to_status='CANCELLED' and reason='二審退回後取消')
    or not exists(select from public.review_records where request_id=r and level=1 and action='APPROVE') then
   raise exception 'missing cancellation or review history';
 end if;
end $$;
rollback;
