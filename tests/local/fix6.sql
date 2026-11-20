\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare applicant uuid; other_manager uuid; r uuid;
begin
  applicant := pg_temp.login('TEST001');
  insert into public.employee_roles(employee_id,role) values(applicant,'DRAWING_MANAGER') on conflict do nothing;
  r := pg_temp.draft();
  perform public.submit_request(r);
  perform pg_temp.login('TEST003');
  perform public.review_level1(r,'APPROVE');
  perform pg_temp.login('TEST001');
  begin
    perform public.review_level2(r,'APPROVE');
    raise exception 'self review accepted';
  exception when raise_exception then
    if sqlerrm not like 'SELF_REVIEW:%' then raise; end if;
  end;
  if exists(select from public.review_records where request_id=r and level=2) then
    raise exception 'unexpected second-level review';
  end if;
  other_manager := pg_temp.login('TEST004');
  perform public.review_level2(r,'APPROVE');
  if not exists(select from public.drawing_requests where id=r and status='PENDING_ISSUE')
     or not exists(select from public.review_records where request_id=r and level=2 and reviewer_id=other_manager and action='APPROVE') then
    raise exception 'independent review failed';
  end if;
end $$;
rollback;
