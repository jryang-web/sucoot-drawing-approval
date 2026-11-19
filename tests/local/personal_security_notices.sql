-- Isolated local fixtures. Invoke with psql -v ON_ERROR_STOP=1.
begin;
-- Deliver each fixture audit twice to exercise the production deduplication key.
create trigger replay_security_notice after insert on public.admin_audit_logs
for each row execute function app.record_personal_security_notice();
select id as recipient from public.employees where employee_no='TEST006' \gset
insert into public.admin_audit_logs(action,target_type,target_id,before,created_at)
select action,'employee', :'recipient', metadata,now()-age from (values
 ('PASSWORD_CHANGED_BY_SELF','{"must_change_password":true}'::jsonb,interval '0'),
 ('PASSWORD_CHANGED_BY_SELF','{"must_change_password":false}',interval '0'),
 ('PASSWORD_RESET',null,interval '0'),
 ('EMPLOYEE_ACTIVATE',null,interval '0'),
 ('PASSWORD_CHANGED_BY_SELF','{"must_change_password":true}',interval '0'),
 ('PASSWORD_RESET',null,interval '31 days')
) as fixture(action,metadata,age);
select max(audit_id) filter(where event='activate') as notice from app.personal_security_notices where employee_id=:'recipient' \gset
select set_config('test.notice', :'notice',true);
select jsonb_build_object('sub',e.auth_user_id,'session_id',s.id)::text as claims
from public.employees e join auth.sessions s on s.user_id=e.auth_user_id where e.employee_no='TEST006' limit 1 \gset
select jsonb_build_object('sub',e.auth_user_id,'session_id',s.id)::text as other_claims
from public.employees e join auth.sessions s on s.user_id=e.auth_user_id where e.employee_no='TEST007' limit 1 \gset
set local role authenticated;
set local request.jwt.claims=:'claims';
do $$
declare seen timestamptz; nid bigint:=current_setting('test.notice')::bigint;
begin
 if (select array_agg(event order by event) from public.my_security_notices()) is distinct from
 array['activate','change','initial','reset'] then raise exception 'incorrect notices'; end if;
 seen:=public.read_security_notice(nid);
 if seen is null or public.read_security_notice(nid) is distinct from seen or
 (select read_at from public.my_security_notices() where id=nid::text) is distinct from seen then raise exception 'read failed'; end if;
end $$;
set local request.jwt.claims=:'other_claims';
do $$
declare nid bigint:=current_setting('test.notice')::bigint;
begin
 if exists(select from public.my_security_notices() where id=nid::text) or public.read_security_notice(nid) is not null
 then raise exception 'recipient isolation failed'; end if;
end $$;
rollback;
