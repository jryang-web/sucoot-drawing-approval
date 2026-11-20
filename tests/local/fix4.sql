\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare employee uuid:=pg_temp.login('TEST001'); admin_no text;
begin
 begin
  perform public.admin_set_drawing_manager(employee,true,'fixture');
  raise exception 'unauthorized role grant';
 exception when raise_exception then if sqlerrm not like 'FORBIDDEN:%' then raise; end if; end;
 select employee_no into strict admin_no from public.employees e where app.has_role('SYS_ADMIN',e.id)
 and exists(select from auth.sessions where user_id=e.auth_user_id) limit 1;
 perform pg_temp.login(admin_no);
 perform public.admin_set_drawing_manager(employee,true,'fixture');
 if not app.has_role('DRAWING_MANAGER',employee) then raise exception 'grant failed'; end if;
 perform public.admin_set_drawing_manager(employee,false,'fixture');
 if app.has_role('DRAWING_MANAGER',employee) then raise exception 'revoke failed'; end if;
end $$;
rollback;
