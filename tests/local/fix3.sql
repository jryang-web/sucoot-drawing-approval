\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare r uuid; other_manager uuid; dept uuid;
begin
 perform pg_temp.login('TEST001'); r:=pg_temp.draft(); perform public.submit_request(r);
 perform pg_temp.login('TEST003'); perform public.review_level1(r,'APPROVE');
 other_manager:=pg_temp.login('TEST007');
 select department_id into dept from public.drawing_requests where id=r;
 insert into public.manager_departments(manager_id,department_id) values(other_manager,dept) on conflict do nothing;
 begin
  perform public.review_level1(r,'REJECT','late',null,0);
  raise exception 'late review accepted';
 exception when raise_exception then if sqlerrm not like 'ALREADY_HANDLED:%' then raise; end if; end;
end $$;
rollback;
