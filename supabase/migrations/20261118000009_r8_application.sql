-- R8 does not ask for a delivery date. Existing dates remain available.
alter table public.drawing_request_items alter column needed_date drop not null;

create function public.save_r8_application(p_purpose text, p_urgent boolean, p_reason text,
  p_note text, p_products jsonb, p_submit boolean) returns uuid
language plpgsql security invoker set search_path = '' as $$
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
  select jsonb_agg(jsonb_build_object('drawing_no',x->>'code','drawing_name',x->>'name',
    'remark',x->>'remark','purpose',p_purpose,'is_urgent',p_urgent,'urgency_reason',p_reason) order by ord)
    into items from jsonb_array_elements(p_products) with ordinality t(x,ord);
  request_id := public.save_draft(null,p_note,items);
  if p_submit then perform public.submit_request(request_id); end if;
  return request_id;
end $$;
revoke all on function public.save_r8_application(text,boolean,text,text,jsonb,boolean) from public,anon;
grant execute on function public.save_r8_application(text,boolean,text,text,jsonb,boolean) to authenticated;
