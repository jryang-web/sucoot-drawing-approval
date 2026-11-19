-- Isolated TEST fixtures only. Business changes are rolled back.
begin;
do $$
declare employee uuid; manager uuid; alternate uuid; department uuid; sample public.drawing_requests;
  k uuid:=gen_random_uuid(); missing uuid:=gen_random_uuid(); pending uuid:=gen_random_uuid(); claims text;
begin
 select e.id,jsonb_build_object('sub',e.auth_user_id,'session_id',s.id)::text into strict employee,claims
 from public.employees e join lateral(select id from auth.sessions where user_id=e.auth_user_id limit 1)s on true
 where e.employee_no='TEST001';
 perform set_config('request.jwt.claims',claims,true);
 select * into strict sample from public.drawing_requests where applicant_id=employee limit 1;
 insert into app.business_operations(id,actor,action,args,result) values
 (k,employee,'submit_request',jsonb_build_object('p_id',sample.id),'{"ok":true}'),
 (pending,employee,'submit_request',jsonb_build_object('p_id',sample.id),null);
 if (select case_id from public.operation_results(array[k]) where id=k) is distinct from sample.request_no then raise exception 'case number'; end if;
 perform public.retire_missing_operation(missing);
 perform public.retire_missing_operation(missing);
 begin
   perform public.prepare_operation(missing,'submit_request',jsonb_build_object('p_id',sample.id,'p_expected_version',1));
   raise exception 'late submission accepted';
 exception when raise_exception then if sqlerrm not like 'OPERATION_CONFLICT:%' then raise; end if; end;
 update public.employees set is_active=false where id=employee;
 update public.employees set is_active=true where id=employee;
 if exists(select from public.operation_results(array[k,missing,pending]) where id in(k,missing,pending))
 or not exists(select from app.business_operations where id=k and result='{"ok":true}' and closed_at is not null)
 or not exists(select from app.business_operations where id=pending and result->>'ok'='false')
 then raise exception 'disable or audit preservation'; end if;

 select e.id,jsonb_build_object('sub',e.auth_user_id,'session_id',s.id)::text into strict manager,claims
 from public.employees e join lateral(select id from auth.sessions where user_id=e.auth_user_id limit 1)s on true
 where e.employee_no='TEST003';
 perform set_config('request.jwt.claims',claims,true);
 select e.id,m.department_id into strict alternate,department from public.employees e
 join public.manager_departments m on m.manager_id=e.id where e.employee_no='TEST007';
 update public.drawing_requests set status='PENDING_DEPT_REVIEW' where id=sample.id;
 if not exists(select from public.v_l1_queue where id=sample.id) then raise exception 'own department'; end if;
 update public.drawing_requests set department_id=department where id=sample.id;
 update public.review_delegations set revoked_at=now() where delegate_id=manager and revoked_at is null;
 if exists(select from public.v_l1_queue where id=sample.id) then raise exception 'unauthorized department'; end if;
 insert into public.review_delegations(principal_id,delegate_id,level,valid_from,valid_to,reason,created_by)
 values(alternate,manager,1,app.today_tpe()-2,app.today_tpe()+2,'P4 fixture',manager);
 if not exists(select from public.v_l1_queue where id=sample.id) then raise exception 'delegated department'; end if;
end $$;
rollback;
