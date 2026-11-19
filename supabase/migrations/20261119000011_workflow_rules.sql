-- Taiwan government office calendar for 2026. Dates outside covered years fail closed.
create table app.office_calendar(day date primary key, is_workday boolean not null);
revoke all on app.office_calendar from public, anon, authenticated;
insert into app.office_calendar
select day, extract(isodow from day)<6 and day not in
  (date '2026-01-01','2026-02-16','2026-02-17','2026-02-18','2026-02-19','2026-02-20','2026-02-27',
   '2026-04-03','2026-04-06','2026-05-01','2026-06-19','2026-09-25','2026-09-28',
   '2026-10-09','2026-10-26','2026-12-25')
from (select date '2026-01-01'+i as day from generate_series(0,364) i) days;

create function app.valid_delegation_period(first_day date,last_day date) returns boolean
language sql stable security definer set search_path='' as $$
 select count(*) = last_day-first_day+1 and count(*) filter(where is_workday) between 1 and 7
 from app.office_calendar where day between first_day and last_day
$$;
revoke all on function app.valid_delegation_period(date,date) from public,anon,authenticated;

alter table public.drawing_requests add column priority_downgraded boolean not null default false;
update public.drawing_requests r set priority_downgraded=true where exists
 (select 1 from public.drawing_request_items i where i.request_id=r.id and i.downgraded_by is not null);
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
  if app.valid_delegation_period(p_valid_from,p_valid_to) is not true then
    perform app.err('INVALID_PERIOD', '期間須已有完整政府辦公日曆，含起訖日最多七個上班日');
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
create or replace function app.l1_authority(p_emp uuid, p_dept uuid, out ok boolean, out delegation_id uuid, out principal_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  ok := false;
  if app.has_role('DEPT_MANAGER', p_emp)
     and exists (select 1 from public.manager_departments where manager_id = p_emp and department_id = p_dept) then
    ok := true; return;
  end if;
  select d.id, d.principal_id into delegation_id, principal_id
    from public.review_delegations d
   where d.delegate_id = p_emp and d.level = 1 and d.revoked_at is null
     and app.valid_delegation_period(d.valid_from,d.valid_to) and app.has_role('DEPT_MANAGER',d.principal_id)
     and app.today_tpe() between d.valid_from and d.valid_to
     and app.has_role('DEPT_MANAGER', p_emp)
     and exists (select 1 from public.manager_departments m where m.manager_id = d.principal_id and m.department_id = p_dept)
   order by d.created_at limit 1;
  ok := delegation_id is not null;
end $$;
create or replace function public.review_level2(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_MANAGER'); r public.drawing_requests; v_l1 uuid; v_del_id uuid; v_del_principal uuid;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_DRAWING_REVIEW');
  select reviewer_id into v_l1 from public.review_records
   where request_id = p_id and round = r.round and level = 1 and action = 'APPROVE' and is_effective;
  if v_l1 is null then perform app.err('LEVEL1_REQUIRED', '尚未完成第一層核准'); end if;
  if v_l1 = me then perform app.err('SAME_REVIEWER', '第一層與第二層審核者不得為同一人'); end if;
  if p_action <> 'APPROVE' then perform app.require_text(p_comment, '審核意見'); end if;

  select d.id, d.principal_id into v_del_id, v_del_principal from public.review_delegations d
   where d.delegate_id = me and d.level = 2 and d.revoked_at is null
     and app.valid_delegation_period(d.valid_from,d.valid_to) and app.has_role('DRAWING_MANAGER',d.principal_id)
     and app.today_tpe() between d.valid_from and d.valid_to
   order by d.created_at limit 1;

  insert into public.review_records (request_id, round, level, action, reviewer_id, delegation_id, on_behalf_of_id, comment)
  values (p_id, r.round, 2, p_action, me, v_del_id, v_del_principal, p_comment);

  if p_action = 'APPROVE' then
    perform app.set_status(p_id, 'PENDING_ISSUE', me, '第二層核准');
  elsif p_action = 'RETURN' then
    update public.drawing_requests set returned_level = 2 where id = p_id;
    perform app.set_status(p_id, 'RETURNED', me, '第二層退回：' || p_comment);
  else
    perform app.set_status(p_id, 'REJECTED', me, '第二層拒絕：' || p_comment);
  end if;
end $$;

create function public.my_l1_departments() returns setof uuid
language sql stable security definer set search_path='' as $$
 select d.id from public.departments d where (app.l1_authority(app.require_employee(),d.id)).ok
$$;
revoke all on function public.my_l1_departments() from public,anon;
grant execute on function public.my_l1_departments() to authenticated;
create or replace function public.submit_request(p_id uuid, p_expected_version int default null, p_resubmit_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; v_content jsonb;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能送出自己的申請'); end if;
  perform app.expect_status(r, 'DRAFT', 'RETURNED');
  if not exists (select 1 from public.drawing_request_items where request_id = p_id) then
    perform app.err('NO_ITEMS', '至少需要一筆圖號');
  end if;
  v_content := app.request_content(p_id);

  if r.status = 'RETURNED' then
    perform app.require_text(p_resubmit_note,'重送說明');
    -- R03/R04：舊核准保留但失效，重新從第一層開始
    update public.review_records set is_effective = false where request_id = p_id and is_effective;
  end if;

  update public.drawing_requests
     set round = round + 1, submitted_at = coalesce(submitted_at,now()), returned_level = null,
         department_id = (select department_id from public.employees where id = me)
   where id = p_id;
  insert into public.request_revisions (request_id, round, snapshot, resubmit_note, submitted_by)
  values (p_id, r.round + 1, v_content, nullif(btrim(p_resubmit_note), ''), me);
  perform app.set_status(p_id, 'PENDING_DEPT_REVIEW',
                         me, case when r.status = 'RETURNED' then '重新送出：' || coalesce(p_resubmit_note, '') else '送出申請' end);
end $$;
create or replace function public.cancel_request(p_id uuid, p_reason text, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能取消自己的申請'); end if;
  perform app.expect_status(r,'PENDING_DEPT_REVIEW');
  perform app.require_text(p_reason,'取消原因');
  if exists(select 1 from public.review_records where request_id=p_id and level=1 and action='APPROVE') then perform app.err('INVALID_STATE','第一層已曾核准'); end if;
  update public.drawing_requests set cancelled_at = now() where id = p_id;
  perform app.set_status(p_id, 'CANCELLED', me, coalesce(nullif(btrim(p_reason), ''), '申請人取消'));
end $$;
create or replace function public.review_level1(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_downgrades jsonb default null, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; a record; d jsonb;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_DEPT_REVIEW');
  select * into a from app.l1_authority(me, r.department_id);
  if not a.ok then perform app.err('FORBIDDEN', '不具此部門第一層審核權限'); end if;
  if p_action <> 'APPROVE' then perform app.require_text(p_comment, '審核意見'); end if;

  if jsonb_array_length(coalesce(p_downgrades,'[]')) > 0 then
    if p_action <> 'APPROVE' or r.priority_downgraded then perform app.err('INVALID_STATE','僅可於核准時調降整案急件一次'); end if;
    perform app.require_text(p_comment,'調降原因');
    update public.drawing_request_items set is_urgent=false,downgraded_by=me,downgrade_reason=btrim(p_comment)
      where request_id=p_id and is_urgent;
    if not found then perform app.err('INVALID_STATE','此案非急件'); end if;
    update public.drawing_requests set priority_downgraded=true where id=p_id;
  end if;
  insert into public.review_records (request_id, round, level, action, reviewer_id, delegation_id, on_behalf_of_id, comment)
  values (p_id, r.round, 1, p_action, me, a.delegation_id, a.principal_id, p_comment);

  if p_action = 'APPROVE' then
    perform app.set_status(p_id, 'PENDING_DRAWING_REVIEW', me, '第一層核准');
  elsif p_action = 'RETURN' then
    update public.drawing_requests set returned_level = 1 where id = p_id;
    perform app.set_status(p_id, 'RETURNED', me, '第一層退回：' || p_comment);
  else
    perform app.set_status(p_id, 'REJECTED', me, '第一層拒絕：' || p_comment);
  end if;
end $$;
create or replace function public.save_draft(p_request_id uuid, p_note text, p_items jsonb, p_expected_version int default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; v_id uuid; it jsonb; n int := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then perform app.err('INVALID_INPUT', 'items 必須為陣列'); end if;
  if p_request_id is null then
    insert into public.drawing_requests (request_no, applicant_id, owner_id, department_id, note)
    select 'DR' || to_char(app.today_tpe(), 'YYYYMMDD') || '-' || lpad(nextval('public.request_no_seq')::text, 5, '0'),
           me, me, e.department_id, p_note
      from public.employees e where e.id = me
    returning id into v_id;
    insert into public.request_status_history (request_id, from_status, to_status, actor_id, reason)
    values (v_id, null, 'DRAFT', me, '建立草稿');
  else
    r := app.lock_request(p_request_id, p_expected_version);
    if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能修改自己的申請'); end if;
    perform app.expect_status(r, 'DRAFT', 'RETURNED');
    if r.priority_downgraded and exists(select 1 from jsonb_array_elements(p_items) x where (x->>'is_urgent')::boolean) then
      perform app.err('INVALID_INPUT','急件已調降，無法恢復');
    end if;
    v_id := r.id;
    update public.drawing_requests set note = p_note where id = v_id;
    delete from public.drawing_request_items where request_id = v_id;
    perform app.touch(v_id);
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    if coalesce((it->>'is_urgent')::boolean, false) and coalesce(btrim(it->>'urgency_reason'), '') = '' then
      perform app.err('URGENCY_REASON_REQUIRED', format('第 %s 筆為急件，請填寫急件原因', n));
    end if;
    insert into public.drawing_request_items (request_id, line_no, drawing_no, drawing_name, revision, purpose,
                                              needed_date, is_urgent, urgency_reason, remark)
    values (v_id, n, btrim(it->>'drawing_no'), btrim(it->>'drawing_name'), nullif(btrim(it->>'revision'), ''),
            btrim(it->>'purpose'), (it->>'needed_date')::date, coalesce((it->>'is_urgent')::boolean, false),
            nullif(btrim(it->>'urgency_reason'), ''), nullif(btrim(it->>'remark'), ''));
  end loop;
  return v_id;
exception when not_null_violation or check_violation or invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
  perform app.err('INVALID_INPUT', '圖號、圖名、申請用途、需求日期為必填');
end $$;
