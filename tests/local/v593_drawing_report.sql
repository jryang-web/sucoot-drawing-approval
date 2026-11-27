-- SUCOOT｜申請紀錄報表（圖管人員）：後端隔離測試
-- 執行：psql -v ON_ERROR_STOP=1 -f tests/local/v593_drawing_report.sql（交易內執行並回滾）
\set ON_ERROR_STOP on
begin;

-- 以指定員工身分執行 SQL，回傳 'OK:<結果>' 或錯誤訊息（who 為 null＝未登入 anon）
create function pg_temp.run(who text, sql text, as_role text default null) returns text language plpgsql as $f$
declare v text; claims text;
begin
  if who is not null then
    select jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text into strict claims
      from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
     where e.employee_no = who;
  end if;
  perform set_config('request.jwt.claims', coalesce(claims, ''), true);
  perform set_config('role', coalesce(as_role, case when who is null then 'anon' else 'authenticated' end), true);
  begin
    execute sql into v; v := 'OK:' || coalesce(v, '');
  exception when others then v := sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $f$;

create temp table t (n text, ok boolean, detail text);
create function pg_temp.chk(n text, ok boolean, detail text default '') returns void language sql as
  $f$ insert into t values (n, coalesce(ok,false), detail) $f$;

select pg_temp.chk('R01 圖管人員可查詢，列數＝非草稿案件的圖面筆數',
  pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1)$q$)
    = 'OK:' || (select count(*) from public.drawing_request_items i join public.drawing_requests r on r.id = i.request_id
                where r.status <> 'DRAFT' and r.submitted_at is not null
                  and (r.submitted_at at time zone 'Asia/Taipei')::date between current_date - 30 and current_date + 1),
  pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1)$q$));
select pg_temp.chk('R02 不含草稿',
  pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1) x join public.drawing_requests r on r.id = x.request_id where r.status = 'DRAFT'$q$) = 'OK:0');
select pg_temp.chk('R03 一般員工被拒', pg_temp.run('TEST001', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date)$q$) like '%權限不足%');
select pg_temp.chk('R04 圖管主管、系統管理員（非圖管人員）被拒',
  pg_temp.run('TEST004', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date)$q$) like '%權限不足%'
  and pg_temp.run('TEST006', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date)$q$) like '%權限不足%');
select pg_temp.chk('R05 未登入被拒', pg_temp.run(null, $q$select count(*)::text from public.drawing_report(current_date - 30, current_date)$q$) not like 'OK:%');
select pg_temp.chk('R06 起日晚於迄日被拒', pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date, current_date - 1)$q$) like '%日期區間%');
select pg_temp.chk('R07 區間超過一年被拒', pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 400, current_date)$q$) like '%最多一年%');
select pg_temp.chk('R08 區間外沒有資料', pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 100, current_date - 60)$q$) = 'OK:0');
select pg_temp.chk('R09 已完成案件帶出發行人與簽收人',
  pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1) where status = 'COMPLETED' and (issued_by is null or received_by is null)$q$) = 'OK:0'
  and pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1) where status = 'COMPLETED'$q$) <> 'OK:0');
select pg_temp.chk('R10 產品編碼原樣輸出（與明細相同）',
  pg_temp.run('TEST005', $q$select count(*)::text from public.drawing_report(current_date - 30, current_date + 1) x join public.drawing_request_items i on i.request_id = x.request_id and i.line_no = x.line_no where i.drawing_no is distinct from x.product_code$q$) = 'OK:0');

select (case when ok then 'PASS ' else 'FAIL ' end) || n || case when detail <> '' then ' — ' || detail else '' end from t;
select count(*) filter (where ok) || '/' || count(*) || ' passed' from t;
rollback;
