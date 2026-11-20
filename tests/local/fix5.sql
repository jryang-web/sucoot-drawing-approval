\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare r uuid;
begin
 perform pg_temp.login('TEST001'); r:=pg_temp.draft();
 insert into public.drawing_request_items(request_id,line_no,drawing_no,drawing_name,purpose)
 values(r,2,'B','test','test');
 begin
  update public.drawing_request_items set is_urgent=true,urgency_reason='fixture' where request_id=r and line_no=1;
  set constraints public.uniform_request_urgency immediate;
  raise exception 'mixed urgency accepted';
 exception when exclusion_violation then null; end;
 update public.drawing_request_items set is_urgent=true,urgency_reason='fixture' where request_id=r;
 set constraints public.uniform_request_urgency immediate;
 update public.drawing_request_items set is_urgent=false where request_id=r;
end $$;
rollback;
