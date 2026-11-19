create table public.case_exceptions (
  request_id uuid primary key references public.drawing_requests(id),
  reason text not null,
  reported_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  withdrawal_reason text
);
alter table public.case_exceptions enable row level security;
revoke all on public.case_exceptions from public, anon, authenticated;
grant select on public.case_exceptions to authenticated;
create policy case_exception_read on public.case_exceptions for select to authenticated
  using (app.has_role('SYS_ADMIN'));

create function public.case_exception(p_id uuid,p_reason text,p_withdraw boolean,p_expected_version int)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid := app.require_employee(); r public.drawing_requests;
begin
  r := app.lock_request(p_id,p_expected_version);
  if r.applicant_id <> actor then perform app.err('FORBIDDEN','僅原申請人可操作'); end if;
  perform app.require_text(p_reason,'原因');
  if p_withdraw then
    perform app.expect_status(r,'ISSUE_ABNORMAL');
    update public.case_exceptions set withdrawn_at=now(),withdrawal_reason=btrim(p_reason)
      where request_id=p_id and withdrawn_at is null;
    if not found then perform app.err('INVALID_STATE','無整案異常可撤回'); end if;
    perform app.set_status(p_id,'PENDING_RECEIPT',actor,'撤回整案異常');
  else
    perform app.expect_status(r,'PENDING_RECEIPT');
    insert into public.case_exceptions(request_id,reason) values(p_id,btrim(p_reason))
      on conflict do nothing;
    if not found then perform app.err('INVALID_STATE','每案限提出一次整案異常'); end if;
    perform app.set_status(p_id,'ISSUE_ABNORMAL',actor,'提出整案異常');
  end if;
end $$;

create function public.admin_force_close(p_id uuid,p_category text,p_reason text,p_expected_version int)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid := app.require_role('SYS_ADMIN'); r public.drawing_requests;
begin
  r := app.lock_request(p_id,p_expected_version);
  perform app.expect_status(r,'PENDING_DEPT_REVIEW','PENDING_DRAWING_REVIEW','RETURNED','PENDING_ISSUE','PENDING_RECEIPT','ISSUE_ABNORMAL');
  if p_category is null or p_category not in ('人員離職','簽收異常','案件無法繼續處理','其他') then
    perform app.err('INVALID_INPUT','請選擇強制結案原因分類');
  end if;
  perform app.require_text(p_reason,'詳細原因');
  update public.drawing_requests set completed_at=now() where id=p_id;
  update public.issue_claims set released_at=now(),released_by=actor,release_reason='管理員強制結案'
    where request_id=p_id and released_at is null;
  perform app.set_status(p_id,'COMPLETED',actor,'管理員強制結案');
  perform app.audit(actor,'FORCE_CLOSE','drawing_request',p_id::text,to_jsonb(r.status),
    jsonb_build_object('category',p_category),btrim(p_reason));
end $$;
revoke all on function public.case_exception(uuid,text,boolean,int),public.admin_force_close(uuid,text,text,int) from public,anon;
grant execute on function public.case_exception(uuid,text,boolean,int),public.admin_force_close(uuid,text,text,int) to authenticated;
revoke execute on function public.report_abnormal(uuid,jsonb,int),public.reissue_item(uuid,text),
  public.confirm_reissued_item(uuid),public.admin_transfer_owner(uuid,uuid,text) from public,anon,authenticated;
