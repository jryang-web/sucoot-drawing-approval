-- 合成測試組織（TEST 帳號）；密碼雜湊為隨機值，不提供登入
do $$
declare d_mfg uuid; d_eng uuid; d_dwg uuid; d_adm uuid; u uuid; e uuid; r record;
begin
  select id into d_adm from public.departments where lower(code) = 'adm';
  insert into public.departments (code, name) values ('MFG','製造部') returning id into d_mfg;
  insert into public.departments (code, name) values ('ENG','工程部') returning id into d_eng;
  insert into public.departments (code, name) values ('DWG','圖管部') returning id into d_dwg;
  for r in select * from (values
    ('TEST001','測試員工A','MFG','{}'::text[]), ('TEST002','測試員工B','MFG','{}'),
    ('TEST003','測試主管A','MFG','{DEPT_MANAGER}'), ('TEST004','測試圖管主管','DWG','{DRAWING_MANAGER}'),
    ('TEST005','測試圖管人員','DWG','{DRAWING_STAFF}'), ('TEST006','測試系統管理員','ADM','{SYS_ADMIN}'),
    ('TEST007','測試主管B','ENG','{DEPT_MANAGER}'), ('TEST008','測試系統管理員B','ADM','{SYS_ADMIN}')) v(no, nm, dept, roles)
  loop
    insert into auth.users (email, encrypted_password) values (lower(r.no)||'@login.sucoot.com', extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf',4))) returning id into u;
    insert into auth.sessions (user_id) values (u);
    insert into public.employees (employee_no, auth_user_id, name, department_id, must_change_password)
      values (r.no, u, r.nm, case r.dept when 'MFG' then d_mfg when 'ENG' then d_eng when 'DWG' then d_dwg else d_adm end, false) returning id into e;
    insert into public.employee_roles (employee_id, role) select e, x::public.app_role from unnest(array['EMPLOYEE'] || r.roles) x;
  end loop;
  insert into auth.sessions (user_id) select auth_user_id from public.employees where employee_no = 'admin';
  insert into public.manager_departments (manager_id, department_id)
    select id, d_mfg from public.employees where employee_no = 'TEST003'
    union all select id, x from public.employees, unnest(array[d_eng]) x where employee_no = 'TEST007';
end $$;
-- TEST001 既有一筆草稿（p4_recovery 測試需要）
select set_config('request.jwt.claims', jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id)::text, false)
  from public.employees e join auth.sessions s on s.user_id = e.auth_user_id where e.employee_no = 'TEST001' limit 1;
select public.save_draft(null, 'fixture', '[{"drawing_no":"FX-001","drawing_name":"既有草稿","purpose":"test","needed_date":"2030-01-01"}]'::jsonb, null);
select set_config('request.jwt.claims', '', false);
