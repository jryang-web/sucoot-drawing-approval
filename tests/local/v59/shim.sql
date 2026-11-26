-- 隔離測試用：模擬 Supabase 平台提供的角色、auth schema 與擴充（非正式環境）
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create role authenticator noinherit login; grant anon, authenticated, service_role to authenticator;
create role supabase_auth_admin nologin; create role supabase_admin nologin;
create schema extensions; create extension pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text unique, encrypted_password text,
  banned_until timestamptz, raw_app_meta_data jsonb default '{}', created_at timestamptz default now(), updated_at timestamptz default now());
create table auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users on delete cascade,
  created_at timestamptz default now(), updated_at timestamptz, not_after timestamptz);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt()->>'sub', '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select auth.jwt()->>'role' $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;
alter schema auth owner to supabase_auth_admin; alter table auth.users owner to supabase_auth_admin; alter table auth.sessions owner to supabase_auth_admin;
grant all on auth.users, auth.sessions to postgres;
-- Supabase 平台預設的 event trigger 函式（migration 0001 會收回其權限）
create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin end $$;
-- 第一位管理者（migration 0004 bootstrap 依 email 綁定）
insert into auth.users (email) values ('admin@login.sucoot.com');
