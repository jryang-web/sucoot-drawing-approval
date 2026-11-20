create or replace function public.cancel_request(p_id uuid, p_reason text, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能取消自己的申請'); end if;
  perform app.expect_status(r,'DRAFT','PENDING_DEPT_REVIEW','RETURNED');
  perform app.require_text(p_reason,'取消原因');
  if r.status <> 'RETURNED' and exists(select 1 from public.review_records where request_id=p_id and level=1 and action='APPROVE') then perform app.err('INVALID_STATE','第一層已曾核准'); end if;
  update public.drawing_requests set cancelled_at = now() where id = p_id;
  perform app.set_status(p_id, 'CANCELLED', me, coalesce(nullif(btrim(p_reason), ''), '申請人取消'));
end $$;
