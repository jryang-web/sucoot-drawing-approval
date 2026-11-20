create or replace function public.review_level1(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_downgrades jsonb default null, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; a record; d jsonb;
begin
  r := app.lock_request(p_id, null);
  select * into a from app.l1_authority(me, r.department_id);
  if not a.ok then perform app.err('FORBIDDEN', '不具此部門第一層審核權限'); end if;
  if r.status <> 'PENDING_DEPT_REVIEW' and exists (
    select from public.review_records where request_id=p_id and round=r.round and level=1 and reviewer_id<>me
  ) then perform app.err('ALREADY_HANDLED','案件已由其他主管處理'); end if;
  perform app.expect_status(r, 'PENDING_DEPT_REVIEW');
  if p_expected_version is not null and r.version<>p_expected_version then
    perform app.err('VERSION_CONFLICT','案件已被其他人更新，請重新整理');
  end if;
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
create or replace function public.review_level2(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_MANAGER'); r public.drawing_requests; v_l1 uuid; v_del_id uuid; v_del_principal uuid;
begin
  r := app.lock_request(p_id, null);
  if r.status <> 'PENDING_DRAWING_REVIEW' and exists (
    select from public.review_records where request_id=p_id and round=r.round and level=2 and reviewer_id<>me
  ) then perform app.err('ALREADY_HANDLED','案件已由其他主管處理'); end if;
  perform app.expect_status(r, 'PENDING_DRAWING_REVIEW');
  if p_expected_version is not null and r.version<>p_expected_version then
    perform app.err('VERSION_CONFLICT','案件已被其他人更新，請重新整理');
  end if;
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
