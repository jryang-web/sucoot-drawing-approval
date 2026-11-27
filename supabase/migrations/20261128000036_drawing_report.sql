-- SUCOOT｜申請紀錄報表（圖管人員）：一筆圖面一列，依送出日期區間（台灣時間）查詢，供列印與下載 Excel
-- 原則：唯讀；後端驗證 DRAWING_STAFF；區間最多 366 天；不含草稿。

create or replace function public.drawing_report(p_from date, p_to date)
returns table (
  request_id uuid, request_no text, submitted_at timestamptz, department text, applicant text,
  line_no int, product_code text, product_name text, revision text, needed_date date, is_urgent boolean,
  status text, receipt_status text, issued_by text, issued_at timestamptz, received_by text, received_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_role('DRAWING_STAFF');
  if p_from is null or p_to is null or p_from > p_to then perform app.err('INVALID_RANGE', '請輸入正確的日期區間'); end if;
  if p_to - p_from > 366 then perform app.err('INVALID_RANGE', '日期區間最多一年'); end if;
  return query
  select r.id, r.request_no, r.submitted_at, d.name, a.name || '（' || a.employee_no || '）',
         i.line_no, i.drawing_no, i.drawing_name, i.revision, i.needed_date, i.is_urgent,
         r.status::text, i.receipt_status,
         ie.name || '（' || ie.employee_no || '）', iss.issued_at,
         re.name || '（' || re.employee_no || '）', rc.created_at
    from public.drawing_requests r
    join public.drawing_request_items i on i.request_id = r.id
    join public.departments d on d.id = r.department_id
    join public.employees a on a.id = r.applicant_id
    left join lateral (select x.issued_by, x.issued_at from public.issue_records x
                        where x.item_id = i.id order by x.issued_at desc limit 1) iss on true
    left join public.employees ie on ie.id = iss.issued_by
    left join lateral (select x.receiver_id, x.created_at from public.receipt_records x
                        where x.request_id = r.id and (x.item_id = i.id or x.item_id is null)
                        order by (x.item_id is null), x.created_at desc limit 1) rc on true
    left join public.employees re on re.id = rc.receiver_id
   where r.status <> 'DRAFT' and r.submitted_at is not null
     and (r.submitted_at at time zone 'Asia/Taipei')::date between p_from and p_to
   order by r.submitted_at, r.request_no, i.line_no;
end $$;

revoke all on function public.drawing_report(date, date) from public, anon;
grant execute on function public.drawing_report(date, date) to authenticated;
