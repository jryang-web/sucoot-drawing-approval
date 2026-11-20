\set ON_ERROR_STOP on
begin;
\ir fix_helpers.sql
do $$
declare principal uuid:=pg_temp.login('TEST003'); delegate uuid; day date:=app.today_tpe()+7;
begin
 select id into strict delegate from public.employees where employee_no='TEST007';
 begin
  perform public.admin_create_delegation(delegate,principal,1::smallint,day,day+2,'fixture');
  raise exception 'impersonation accepted';
 exception when raise_exception then if sqlerrm not like 'FORBIDDEN:%' then raise; end if; end;
 perform public.admin_create_delegation(principal,delegate,1::smallint,day,day+2,'fixture');
end $$;
rollback;
