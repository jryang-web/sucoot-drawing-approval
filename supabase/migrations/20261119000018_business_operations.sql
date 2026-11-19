-- Bind the intent before executing it. No client has direct table access.
create table app.business_operations (
  id uuid primary key,
  actor uuid not null references public.employees(id),
  action text not null,
  args jsonb not null,
  result jsonb,
  created_at timestamptz not null default now(),
  shown_at timestamptz
);
revoke all on app.business_operations from public,anon,authenticated;
create index business_operations_inbox on app.business_operations(actor,created_at) where shown_at is null;

create function public.prepare_operation(p_key uuid,p_action text,p_args jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=app.require_employee(); existing app.business_operations;
begin
  if p_key is null or p_action is null or jsonb_typeof(p_args) is distinct from 'object'
    or p_action not in ('write_r8_application','submit_request','review_level1','review_level2',
      'claim_issue','record_issue','case_exception','confirm_receipt','admin_force_close') then
    perform app.err('INVALID_INPUT','操作資料不完整');
  end if;
  if p_action='write_r8_application' then
    if p_args->>'p_id' is not null and p_args->>'p_version' is null then perform app.err('INVALID_INPUT','案件版本必填'); end if;
    if p_args->'p_submit' is distinct from 'true'::jsonb then perform app.err('INVALID_INPUT','僅限正式送件'); end if;
  elsif p_args->>'p_id' is null or p_args->>'p_expected_version' is null then
    perform app.err('INVALID_INPUT','案件及版本必填');
  end if;
  if p_action in ('review_level1','review_level2') and p_args->>'p_action' is null
    or p_action='case_exception' and jsonb_typeof(p_args->'p_withdraw') is distinct from 'boolean' then
    perform app.err('INVALID_INPUT','操作內容不完整');
  end if;
  insert into app.business_operations(id,actor,action,args) values(p_key,actor_id,p_action,p_args)
    on conflict(id) do nothing;
  if not found then
    select * into strict existing from app.business_operations where id=p_key;
    if existing.actor<>actor_id or existing.action<>p_action or existing.args<>p_args then
      perform app.err('OPERATION_CONFLICT','操作識別碼已綁定其他內容');
    end if;
  end if;
end $$;

create function public.execute_operation(p_key uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=app.require_employee(); op app.business_operations; a jsonb;
  case_id uuid; ver integer; number text; outcome jsonb;
begin
  begin
    select * into op from app.business_operations where id=p_key and actor=actor_id for update nowait;
    if not found then perform app.err('NOT_FOUND','沒有此操作'); end if;
  exception when lock_not_available then perform app.err('IN_PROGRESS','操作處理中，請稍後重試');
  end;
  if op.result is not null then return op.result; end if;
  a:=op.args;
  begin
    case_id:=(a->>'p_id')::uuid;
    ver:=(a->>'p_expected_version')::int;
    case op.action
      when 'write_r8_application' then
        case_id:=public.write_r8_application(a->>'p_purpose',(a->>'p_urgent')::boolean,
          a->>'p_reason',a->>'p_note',a->'p_products',true,case_id,(a->>'p_version')::int);
      when 'submit_request' then perform public.submit_request(case_id,ver,a->>'p_resubmit_note');
      when 'review_level1' then perform public.review_level1(case_id,(a->>'p_action')::public.review_action,a->>'p_comment',a->'p_downgrades',ver);
      when 'review_level2' then perform public.review_level2(case_id,(a->>'p_action')::public.review_action,a->>'p_comment',ver);
      when 'claim_issue' then perform public.claim_issue(case_id,ver);
      when 'record_issue' then perform public.record_issue(case_id,a->>'p_line_note',ver);
      when 'case_exception' then perform public.case_exception(case_id,a->>'p_reason',(a->>'p_withdraw')::boolean,ver);
      when 'confirm_receipt' then perform public.confirm_receipt(case_id,ver);
      when 'admin_force_close' then perform public.admin_force_close(case_id,a->>'p_category',a->>'p_reason',ver);
    end case;
    select request_no into strict number from public.drawing_requests where id=case_id;
    outcome:=jsonb_build_object('ok',true,'id',case_id,'number',number);
  exception when raise_exception or data_exception or integrity_constraint_violation then
    -- This subtransaction rolls back all side effects, including audit and mock events.
    outcome:=jsonb_build_object('ok',false,'error',case when sqlstate='P0001' then sqlerrm else 'INVALID_INPUT: 操作資料不符' end);
  end;
  update app.business_operations set result=outcome where id=p_key;
  return outcome;
end $$;

create function public.operation_results(p_keys uuid[] default '{}')
returns table(id uuid,action text,case_id text,result jsonb) language sql security definer set search_path='' as $$
 select b.id,case when b.action='case_exception' and b.args->>'p_withdraw'='true' then 'withdraw_exception'
                  when b.action='submit_request' and b.args->>'p_resubmit_note' is not null then 'resubmit'
                  else b.action end,
        coalesce(b.result->>'id',b.args->>'p_id'),b.result
 from app.business_operations b where b.actor=app.require_employee() and (b.shown_at is null or b.id=any(p_keys))
 order by b.created_at,b.id
$$;
create function public.ack_operation_results(p_keys uuid[]) returns void language sql security definer set search_path='' as $$
 update app.business_operations set shown_at=now() where actor=app.require_employee() and id=any(p_keys)
 and result is not null and shown_at is null
$$;

create function app.cancel_pending_employee_ops() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update app.business_operations set result=jsonb_build_object('ok',false,'error','CANCELLED: 帳號安全異動，未提交的操作已取消')
   where actor=new.id and result is null;
  return new;
end $$;
create trigger cancel_pending_on_credential_rotation after update of must_change_password on public.employees
for each row execute function app.cancel_pending_employee_ops();
create trigger cancel_pending_on_disable after update of is_active on public.employees
for each row when(old.is_active and not new.is_active) execute function app.cancel_pending_employee_ops();

-- Drafts can still be saved without an operation key. Submission is reachable only via the ledger.
create function public.save_r8_draft(p_purpose text,p_urgent boolean,p_reason text,p_note text,p_products jsonb,p_id uuid,p_version int)
returns uuid language sql security definer set search_path='' as $$
 select public.write_r8_application(p_purpose,p_urgent,p_reason,p_note,p_products,false,p_id,p_version)
$$;
revoke execute on function public.write_r8_application(text,boolean,text,text,jsonb,boolean,uuid,int),
 public.save_r8_application(text,boolean,text,text,jsonb,boolean),public.submit_request(uuid,int,text),
 public.review_level1(uuid,public.review_action,text,jsonb,int),public.review_level2(uuid,public.review_action,text,int),
 public.claim_issue(uuid,int),public.record_issue(uuid,text,int),public.case_exception(uuid,text,boolean,int),
 public.confirm_receipt(uuid,int),public.admin_force_close(uuid,text,text,int) from public,anon,authenticated;
revoke all on function app.cancel_pending_employee_ops(), public.save_r8_draft(text,boolean,text,text,jsonb,uuid,int),
 public.prepare_operation(uuid,text,jsonb),public.execute_operation(uuid),public.operation_results(uuid[]),public.ack_operation_results(uuid[])
 from public,anon,authenticated;
grant execute on function public.save_r8_draft(text,boolean,text,text,jsonb,uuid,int),
 public.prepare_operation(uuid,text,jsonb),public.execute_operation(uuid),public.operation_results(uuid[]),public.ack_operation_results(uuid[])
 to authenticated;
