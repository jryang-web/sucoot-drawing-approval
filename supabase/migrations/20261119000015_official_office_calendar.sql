-- 行政院人事行政總處：中華民國政府行政機關辦公日曆表
-- https://data.gov.tw/dataset/14718 (政府資料開放授權條款第 1 版)
-- Daily flags transcribed from the JSON mirror, revision 73d814e768c94f2426af0787c96658d69068c3ff:
-- https://github.com/ruyut/TaiwanCalendar/tree/73d814e768c94f2426af0787c96658d69068c3ff/data
-- Every listed month is complete. The array lists every non-working day, including weekends.
with months(first_day, days_off) as (values
  (date '2017-01-01', array[1, 2, 7, 8, 14, 15, 21, 22, 27, 28, 29, 30, 31]::int[]),
  (date '2017-02-01', array[1, 4, 5, 11, 12, 19, 25, 26, 27, 28]::int[]),
  (date '2017-03-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2017-04-01', array[1, 2, 3, 4, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2017-05-01', array[6, 7, 13, 14, 20, 21, 27, 28, 29, 30]::int[]),
  (date '2017-06-01', array[4, 10, 11, 17, 18, 24, 25]::int[]),
  (date '2017-07-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2017-08-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2017-09-01', array[2, 3, 9, 10, 16, 17, 23, 24]::int[]),
  (date '2017-10-01', array[1, 4, 7, 8, 9, 10, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2017-11-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2017-12-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2018-01-01', array[1, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2018-02-01', array[3, 4, 10, 11, 15, 16, 17, 18, 19, 20, 24, 25, 28]::int[]),
  (date '2018-03-01', array[3, 4, 10, 11, 17, 18, 24, 25]::int[]),
  (date '2018-04-01', array[1, 4, 5, 6, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2018-05-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2018-06-01', array[2, 3, 9, 10, 16, 17, 18, 23, 24, 30]::int[]),
  (date '2018-07-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2018-08-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2018-09-01', array[1, 2, 8, 9, 15, 16, 22, 23, 24, 29, 30]::int[]),
  (date '2018-10-01', array[6, 7, 10, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2018-11-01', array[3, 4, 10, 11, 17, 18, 24, 25]::int[]),
  (date '2018-12-01', array[1, 2, 8, 9, 15, 16, 23, 29, 30, 31]::int[]),
  (date '2019-01-01', array[1, 5, 6, 12, 13, 20, 26, 27]::int[]),
  (date '2019-02-01', array[2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 17, 24, 28]::int[]),
  (date '2019-03-01', array[1, 2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2019-04-01', array[4, 5, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2019-05-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2019-06-01', array[1, 2, 7, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2019-07-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2019-08-01', array[3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2019-09-01', array[1, 7, 8, 13, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2019-10-01', array[6, 10, 11, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2019-11-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30]::int[]),
  (date '2019-12-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2020-01-01', array[1, 4, 5, 11, 12, 18, 19, 23, 24, 25, 26, 27, 28, 29]::int[]),
  (date '2020-02-01', array[1, 2, 8, 9, 16, 22, 23, 28, 29]::int[]),
  (date '2020-03-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2020-04-01', array[2, 3, 4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2020-05-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2020-06-01', array[6, 7, 13, 14, 21, 25, 26, 27, 28]::int[]),
  (date '2020-07-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2020-08-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2020-09-01', array[5, 6, 12, 13, 19, 20, 27]::int[]),
  (date '2020-10-01', array[1, 2, 3, 4, 9, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2020-11-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2020-12-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2021-01-01', array[1, 2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2021-02-01', array[6, 7, 10, 11, 12, 13, 14, 15, 16, 21, 27, 28]::int[]),
  (date '2021-03-01', array[1, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2021-04-01', array[2, 3, 4, 5, 10, 11, 17, 18, 24, 25]::int[]),
  (date '2021-05-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2021-06-01', array[5, 6, 12, 13, 14, 19, 20, 26, 27]::int[]),
  (date '2021-07-01', array[3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2021-08-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2021-09-01', array[4, 5, 12, 18, 19, 20, 21, 25, 26]::int[]),
  (date '2021-10-01', array[2, 3, 9, 10, 11, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2021-11-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2021-12-01', array[4, 5, 11, 12, 18, 19, 25, 26, 31]::int[]),
  (date '2022-01-01', array[1, 2, 8, 9, 15, 16, 23, 29, 30, 31]::int[]),
  (date '2022-02-01', array[1, 2, 3, 4, 5, 6, 12, 13, 19, 20, 26, 27, 28]::int[]),
  (date '2022-03-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2022-04-01', array[2, 3, 4, 5, 9, 10, 16, 17, 23, 24, 30]::int[]),
  (date '2022-05-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2022-06-01', array[3, 4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2022-07-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2022-08-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2022-09-01', array[3, 4, 9, 10, 11, 17, 18, 24, 25]::int[]),
  (date '2022-10-01', array[1, 2, 8, 9, 10, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2022-11-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2022-12-01', array[3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2023-01-01', array[1, 2, 8, 14, 15, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]::int[]),
  (date '2023-02-01', array[5, 11, 12, 19, 25, 26, 27, 28]::int[]),
  (date '2023-03-01', array[4, 5, 11, 12, 18, 19, 26]::int[]),
  (date '2023-04-01', array[1, 2, 3, 4, 5, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2023-05-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2023-06-01', array[3, 4, 10, 11, 18, 22, 23, 24, 25]::int[]),
  (date '2023-07-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2023-08-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2023-09-01', array[2, 3, 9, 10, 16, 17, 24, 29, 30]::int[]),
  (date '2023-10-01', array[1, 7, 8, 9, 10, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2023-11-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2023-12-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2024-01-01', array[1, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2024-02-01', array[3, 4, 8, 9, 10, 11, 12, 13, 14, 18, 24, 25, 28]::int[]),
  (date '2024-03-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2024-04-01', array[4, 5, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2024-05-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2024-06-01', array[1, 2, 8, 9, 10, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2024-07-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2024-08-01', array[3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2024-09-01', array[1, 7, 8, 14, 15, 17, 21, 22, 28, 29]::int[]),
  (date '2024-10-01', array[5, 6, 10, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2024-11-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30]::int[]),
  (date '2024-12-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2025-01-01', array[1, 4, 5, 11, 12, 18, 19, 25, 26, 27, 28, 29, 30, 31]::int[]),
  (date '2025-02-01', array[1, 2, 9, 15, 16, 22, 23, 28]::int[]),
  (date '2025-03-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2025-04-01', array[3, 4, 5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2025-05-01', array[3, 4, 10, 11, 17, 18, 24, 25, 30, 31]::int[]),
  (date '2025-06-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2025-07-01', array[5, 6, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2025-08-01', array[2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2025-09-01', array[6, 7, 13, 14, 20, 21, 27, 28, 29]::int[]),
  (date '2025-10-01', array[4, 5, 6, 10, 11, 12, 18, 19, 24, 25, 26]::int[]),
  (date '2025-11-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2025-12-01', array[6, 7, 13, 14, 20, 21, 25, 27, 28]::int[]),
  (date '2026-01-01', array[1, 3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2026-02-01', array[1, 7, 8, 14, 15, 16, 17, 18, 19, 20, 21, 22, 27, 28]::int[]),
  (date '2026-03-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2026-04-01', array[3, 4, 5, 6, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2026-05-01', array[1, 2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2026-06-01', array[6, 7, 13, 14, 19, 20, 21, 27, 28]::int[]),
  (date '2026-07-01', array[4, 5, 11, 12, 18, 19, 25, 26]::int[]),
  (date '2026-08-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2026-09-01', array[5, 6, 12, 13, 19, 20, 25, 26, 27, 28]::int[]),
  (date '2026-10-01', array[3, 4, 9, 10, 11, 17, 18, 24, 25, 26, 31]::int[]),
  (date '2026-11-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2026-12-01', array[5, 6, 12, 13, 19, 20, 25, 26, 27]::int[]),
  (date '2027-01-01', array[1, 2, 3, 9, 10, 16, 17, 23, 24, 30, 31]::int[]),
  (date '2027-02-01', array[4, 5, 6, 7, 8, 9, 10, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2027-03-01', array[1, 6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2027-04-01', array[3, 4, 5, 6, 10, 11, 17, 18, 24, 25, 30]::int[]),
  (date '2027-05-01', array[1, 2, 8, 9, 15, 16, 22, 23, 29, 30]::int[]),
  (date '2027-06-01', array[5, 6, 9, 12, 13, 19, 20, 26, 27]::int[]),
  (date '2027-07-01', array[3, 4, 10, 11, 17, 18, 24, 25, 31]::int[]),
  (date '2027-08-01', array[1, 7, 8, 14, 15, 21, 22, 28, 29]::int[]),
  (date '2027-09-01', array[4, 5, 11, 12, 15, 18, 19, 25, 26, 28]::int[]),
  (date '2027-10-01', array[2, 3, 9, 10, 11, 16, 17, 23, 24, 25, 30, 31]::int[]),
  (date '2027-11-01', array[6, 7, 13, 14, 20, 21, 27, 28]::int[]),
  (date '2027-12-01', array[4, 5, 11, 12, 18, 19, 24, 25, 26, 31]::int[])
)
insert into app.office_calendar(day,is_workday)
select first_day+n-1, not (n=any(days_off))
from months cross join lateral generate_series(1, extract(day from first_day+interval '1 month - 1 day')::int) n
on conflict(day) do update set is_workday=excluded.is_workday
where office_calendar.is_workday is distinct from excluded.is_workday;

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
  if (select count(*) from app.office_calendar where day between p_valid_from and p_valid_to)
     <> p_valid_to-p_valid_from+1 then
    perform app.err('CALENDAR_INCOMPLETE','代理期間缺少已公布的政府辦公日資料，無法確認工作日數');
  end if;
  if app.valid_delegation_period(p_valid_from,p_valid_to) is not true then
    perform app.err('INVALID_PERIOD', '含起訖日須有一至七個政府上班日');
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
