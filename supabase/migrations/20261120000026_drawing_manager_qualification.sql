create function public.admin_set_drawing_manager(p_employee uuid, p_grant boolean, p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=app.require_role('SYS_ADMIN'); previous jsonb;
begin
  perform app.require_text(p_reason,'變更原因');
  if p_grant is null then perform app.err('INVALID_INPUT','請指定授予或撤銷'); end if;
  perform 1 from public.employees where id=p_employee for update;
  if not found then perform app.err('NOT_FOUND','員工不存在'); end if;
  previous:=app.employee_snapshot(p_employee);
  if p_grant then
    insert into public.employee_roles(employee_id,role,granted_by)
    values(p_employee,'DRAWING_MANAGER',actor) on conflict do nothing;
  else
    delete from public.employee_roles where employee_id=p_employee and role='DRAWING_MANAGER';
  end if;
  if found then
    perform app.audit(actor,'EMPLOYEE_ROLES','employee',p_employee::text,previous,
                      app.employee_snapshot(p_employee),btrim(p_reason));
  end if;
end $$;
revoke all on function public.admin_set_drawing_manager(uuid,boolean,text) from public,anon;
grant execute on function public.admin_set_drawing_manager(uuid,boolean,text) to authenticated;
