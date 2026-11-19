create or replace function public.manage_employee_login(p_employee uuid,p_action text,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app.require_role('SYS_ADMIN'); emp public.employees; secret text;
begin
  perform app.require_text(p_reason,'原因');
  if not(case p_action
    when 'reset' then p_reason in ('忘記密碼','臨時密碼遺失','資安需求','管理員要求')
    when 'activate' then p_reason in ('復職','職務調整完成','資安問題解除','恢復使用')
    when 'deactivate' then p_reason in ('離職','職務異動','資安風險','暫停使用')
    else false end or (left(p_reason,3)='其他：' and btrim(substr(p_reason,4))<>''))
    then perform app.err('INVALID_INPUT','請選擇有效原因，其他原因須填說明'); end if;
  if p_employee=actor then perform app.err('FORBIDDEN','不可在後台重設或停用自己的帳號'); end if;
  select * into emp from public.employees where id=p_employee for update;
  if not found then perform app.err('NOT_FOUND','員工不存在'); end if;
  if p_action='reset' then
    secret:=encode(extensions.gen_random_bytes(16),'hex');
    perform app.rotate_employee_password(emp,secret,true);
    perform app.audit(actor,'PASSWORD_RESET','employee',emp.id::text,null,null,p_reason);
  elsif p_action in ('activate','deactivate') then
    if emp.is_active=(p_action='activate') then perform app.err('INVALID_STATE','帳號狀態已變更'); end if;
    perform public.svc_set_active(auth.uid(),emp.id,p_action='activate',p_reason);
    update auth.users set banned_until=case when p_action='deactivate' then now()+interval '100 years' end
      where id=emp.auth_user_id;
    if p_action='activate' then
      secret:=encode(extensions.gen_random_bytes(16),'hex');
      perform app.rotate_employee_password(emp,secret,true);
    else
      delete from auth.sessions where user_id=emp.auth_user_id;
    end if;
  else perform app.err('INVALID_INPUT','未知的帳號操作');
  end if;
  return jsonb_strip_nulls(jsonb_build_object('ok',true,'new_password',secret));
end $$;
create index admin_exception_notes_case_id on public.admin_audit_logs(target_id,id desc) where target_type='drawing_request' and action='EXCEPTION_NOTE';
