-- SUCOOT V5.7 | 0001 組織、員工、角色、稽核、共用 helper
-- 原則：前端（anon/authenticated）只能 SELECT（受 RLS 限制），所有寫入一律經由 SECURITY DEFINER RPC。

create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- Supabase 預設 event trigger 函式不應被 API 呼叫（Security Advisor 0028/0029）
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- 新建函式預設不開放給 public / anon
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema app revoke execute on functions from public;

create type public.app_role as enum ('EMPLOYEE','DEPT_MANAGER','DRAWING_MANAGER','DRAWING_STAFF','SYS_ADMIN');

-- ---------------------------------------------------------------- tables
create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  code        text not null check (code ~ '^[A-Za-z0-9_-]{1,20}$'),
  name        text not null check (length(btrim(name)) between 1 and 50),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index departments_code_key on public.departments (lower(code));
create unique index departments_name_key on public.departments (name);

create table public.employees (
  id                   uuid primary key default gen_random_uuid(),
  employee_no          text not null check (employee_no ~ '^[A-Za-z0-9_-]{2,32}$'),
  auth_user_id         uuid unique references auth.users(id) on delete set null,
  name                 text not null check (length(btrim(name)) between 1 and 50),
  department_id        uuid not null references public.departments(id),
  is_active            boolean not null default true,
  must_change_password boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deactivated_at       timestamptz
);
create unique index employees_no_key on public.employees (lower(employee_no));
create index employees_department_idx on public.employees (department_id);

create table public.employee_roles (
  employee_id uuid not null references public.employees(id),
  role        public.app_role not null,
  granted_at  timestamptz not null default now(),
  granted_by  uuid references public.employees(id),
  primary key (employee_id, role)
);

create table public.manager_departments (
  manager_id    uuid not null references public.employees(id),
  department_id uuid not null references public.departments(id),
  created_at    timestamptz not null default now(),
  created_by    uuid references public.employees(id),
  primary key (manager_id, department_id)
);
create index manager_departments_dept_idx on public.manager_departments (department_id);

create table public.admin_audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid references public.employees(id),
  action      text not null,
  target_type text not null,
  target_id   text,
  before      jsonb,
  after       jsonb,
  reason      text,
  created_at  timestamptz not null default now()
);
create index admin_audit_logs_created_idx on public.admin_audit_logs (created_at desc);

alter table public.departments          enable row level security;
alter table public.employees            enable row level security;
alter table public.employee_roles       enable row level security;
alter table public.manager_departments  enable row level security;
alter table public.admin_audit_logs     enable row level security;

-- 前端不得直接寫入（RLS 之外的第二道防線）
revoke all on public.departments, public.employees, public.employee_roles,
              public.manager_departments, public.admin_audit_logs from anon;
revoke insert, update, delete, truncate on public.departments, public.employees, public.employee_roles,
              public.manager_departments, public.admin_audit_logs from authenticated;

-- ---------------------------------------------------------------- 不可改寫的紀錄表
create or replace function app.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'IMMUTABLE: % 為歷史紀錄，不可修改或刪除', tg_table_name using errcode = 'P0001';
end $$;

create trigger admin_audit_logs_immutable before update or delete on public.admin_audit_logs
  for each row execute function app.forbid_change();

-- ---------------------------------------------------------------- helpers
create or replace function app.err(p_code text, p_msg text) returns void
language plpgsql as $$
begin
  raise exception '%: %', p_code, p_msg using errcode = 'P0001';
end $$;

create or replace function app.current_employee_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select e.id from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active
$$;

create or replace function app.has_role(p_role public.app_role, p_emp uuid default null) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.employee_roles r join public.employees e on e.id = r.employee_id
    where r.employee_id = coalesce(p_emp, app.current_employee_id()) and r.role = p_role and e.is_active
  )
$$;

-- 每支業務 RPC 的第一行：確認登入者為啟用中員工，且已完成首次改密碼
create or replace function app.require_employee() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid; v_must boolean;
begin
  if auth.uid() is null then perform app.err('UNAUTHENTICATED', '尚未登入'); end if;
  select e.id, e.must_change_password into v_id, v_must
    from public.employees e where e.auth_user_id = auth.uid() and e.is_active;
  if v_id is null then perform app.err('ACCOUNT_INACTIVE', '帳號不存在或已停用'); end if;
  if v_must then perform app.err('PASSWORD_CHANGE_REQUIRED', '請先修改密碼'); end if;
  return v_id;
end $$;

create or replace function app.require_role(p_role public.app_role) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid := app.require_employee();
begin
  if not app.has_role(p_role, v_id) then perform app.err('FORBIDDEN', '權限不足：需要 ' || p_role); end if;
  return v_id;
end $$;

create or replace function app.audit(p_actor uuid, p_action text, p_target_type text, p_target_id text,
                                     p_before jsonb, p_after jsonb, p_reason text) returns void
language sql security definer set search_path = '' as $$
  insert into public.admin_audit_logs (actor_id, action, target_type, target_id, before, after, reason)
  values (p_actor, p_action, p_target_type, p_target_id, p_before, p_after, p_reason)
$$;

create or replace function app.employee_snapshot(p_emp uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'employee_no', e.employee_no, 'name', e.name, 'department_id', e.department_id,
    'is_active', e.is_active,
    'roles', coalesce((select jsonb_agg(r.role order by r.role) from public.employee_roles r where r.employee_id = e.id), '[]'),
    'manager_departments', coalesce((select jsonb_agg(m.department_id order by m.department_id) from public.manager_departments m where m.manager_id = e.id), '[]'))
  from public.employees e where e.id = p_emp
$$;

-- 至少保留一位啟用中的系統管理員（A1）
create or replace function app.assert_admin_remains() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.employee_roles r join public.employees e on e.id = r.employee_id
                 where r.role = 'SYS_ADMIN' and e.is_active) then
    perform app.err('LAST_ADMIN', '系統至少須保留一位啟用中的系統管理員');
  end if;
end $$;

grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function app.audit(uuid,text,text,text,jsonb,jsonb,text) from authenticated;

-- ---------------------------------------------------------------- RLS（只開放 SELECT）
create policy departments_select on public.departments for select to authenticated
  using (app.current_employee_id() is not null);
create policy employees_select on public.employees for select to authenticated
  using (app.current_employee_id() is not null);
create policy employee_roles_select on public.employee_roles for select to authenticated
  using (app.current_employee_id() is not null);
create policy manager_departments_select on public.manager_departments for select to authenticated
  using (app.current_employee_id() is not null);
create policy admin_audit_logs_select on public.admin_audit_logs for select to authenticated
  using (app.has_role('SYS_ADMIN'));
