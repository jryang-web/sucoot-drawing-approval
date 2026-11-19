-- Weekends are the only excluded days. Keep existing grants and stored deadlines.
create or replace function app.valid_delegation_period(first_day date,last_day date)
returns boolean language sql immutable set search_path='' as $$
  select case
    when first_day is null or last_day is null or not isfinite(first_day) or not isfinite(last_day)
      or last_day < first_day then false
    -- Two complete weeks always contain ten weekdays; bound work for long ranges.
    when last_day-first_day >= 13 then false
    else (select count(*) between 1 and 7
          from generate_series(0,last_day-first_day) as days(offset_days)
          where extract(isodow from first_day+offset_days) between 1 and 5)
  end
$$;

create or replace function public.admin_create_delegation(p_principal uuid, p_delegate uuid, p_level smallint,
                                                          p_valid_from date, p_valid_to date, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('SYS_ADMIN'); v_role public.app_role; v_id uuid;
begin
  perform app.require_text(p_reason, '代理原因');
  v_role := case p_level when 1 then 'DEPT_MANAGER'::public.app_role when 2 then 'DRAWING_MANAGER'::public.app_role end;
  if v_role is null then perform app.err('INVALID_INPUT', 'level 必須為 1 或 2'); end if;
  if not app.has_role(v_role, p_principal) then perform app.err('INVALID_PRINCIPAL', '被代理人不具該層審核角色'); end if;
  if not app.has_role(v_role, p_delegate) then perform app.err('INVALID_DELEGATE', '代理人須具備相同審核角色且為啟用中'); end if;
  if p_valid_from is null or p_valid_to is null or p_valid_from>p_valid_to then
    perform app.err('INVALID_PERIOD','請確認代理開始日及結束日');
  end if;
  if app.valid_delegation_period(p_valid_from,p_valid_to) is not true then
    perform app.err('INVALID_PERIOD', '起訖日合計須有一至七個工作日（週一至週五）');
  end if;
  perform 1 from public.employees where id=p_principal for update;
  if exists (select 1 from public.review_delegations d where d.principal_id = p_principal and d.level = p_level
             and d.revoked_at is null and daterange(d.valid_from, d.valid_to, '[]') && daterange(p_valid_from, p_valid_to, '[]')) then
    perform app.err('DELEGATION_OVERLAP', '此期間已有代理設定');
  end if;
  insert into public.review_delegations (principal_id, delegate_id, level, valid_from, valid_to, reason, created_by)
  values (p_principal, p_delegate, p_level, p_valid_from, p_valid_to, btrim(p_reason), me) returning id into v_id;
  perform app.audit(me, 'DELEGATION_CREATE', 'review_delegation', v_id::text, null,
                    (select to_jsonb(d) from public.review_delegations d where d.id = v_id), p_reason);
  return v_id;
end $$;
