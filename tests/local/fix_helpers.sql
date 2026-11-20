-- Run only against the synthetic local database with existing TEST login sessions.
create function pg_temp.login(employee_number text) returns uuid language plpgsql as $$
declare employee uuid; claims text;
begin
 select e.id,jsonb_build_object('sub',e.auth_user_id,'session_id',s.id)::text into strict employee,claims
 from public.employees e join lateral(select id from auth.sessions where user_id=e.auth_user_id order by created_at desc limit 1)s on true
 where e.employee_no=employee_number;
 perform set_config('request.jwt.claims',claims,true);
 return employee;
end $$;
create function pg_temp.draft() returns uuid language sql as $$
 select public.save_draft(null,'fixture','[{"drawing_no":"A","drawing_name":"test","purpose":"test","needed_date":"2030-01-01"}]'::jsonb,null)
$$;
