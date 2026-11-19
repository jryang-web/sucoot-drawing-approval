create function public.write_r8_application(p_purpose text, p_urgent boolean, p_reason text,
  p_note text, p_products jsonb, p_submit boolean,p_id uuid,p_version int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare request_id uuid; items jsonb;
begin
  if nullif(trim(p_purpose),'') is null or jsonb_typeof(p_products) is distinct from 'array'
    or jsonb_array_length(p_products) not between 1 and 5 then
    raise exception 'INVALID_INPUT: 請填寫用途與一至五筆產品';
  end if;
  if exists (select 1 from jsonb_array_elements(p_products) x where
      coalesce(trim(x->>'code'),'') !~ '^[A-Za-z0-9_./-]{1,30}$' or nullif(trim(x->>'name'),'') is null)
    or (select count(distinct trim(x->>'code')) from jsonb_array_elements(p_products) x) <> jsonb_array_length(p_products)
  then raise exception 'INVALID_INPUT: 請核對產品編碼與品名'; end if;
  perform app.require_employee();
  if p_id is not null and not exists(select 1 from public.drawing_requests r
    where r.id=p_id and r.applicant_id=app.current_employee_id() and r.owner_id=r.applicant_id) then
    perform app.err('FORBIDDEN','只能編輯自己的案件');
  end if;
  select jsonb_agg(jsonb_build_object('drawing_no',x->>'code','drawing_name',x->>'name',
    'revision',old.revision,'needed_date',old.needed_date,'remark',x->>'remark','purpose',p_purpose,'is_urgent',p_urgent,'urgency_reason',p_reason) order by ord)
    into items from jsonb_array_elements(p_products) with ordinality t(x,ord) left join public.drawing_request_items old on old.request_id=p_id and old.drawing_no=trim(x->>'code');
  request_id := public.save_draft(p_id,p_note,items,p_version);
  if p_submit then perform public.submit_request(request_id); end if;
  return request_id;
end $$;

create or replace function public.save_r8_application(p_purpose text,p_urgent boolean,p_reason text,p_note text,p_products jsonb,p_submit boolean)
returns uuid language sql security invoker set search_path='' as $$
 select public.write_r8_application(p_purpose,p_urgent,p_reason,p_note,p_products,p_submit,null,null)
$$;
revoke all on function public.write_r8_application(text,boolean,text,text,jsonb,boolean,uuid,int) from public,anon;
grant execute on function public.write_r8_application(text,boolean,text,text,jsonb,boolean,uuid,int) to authenticated;
revoke execute on function public.save_draft(uuid,text,jsonb,int) from public,anon,authenticated;
