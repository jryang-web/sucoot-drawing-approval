create table public.line_mock_events (
  request_id uuid not null references public.drawing_requests(id),
  event text not null check(event in ('initial','issue')),
  actor_id uuid not null references public.employees(id),
  occurred_at timestamptz not null default now(),
  message text not null,
  simulated_at timestamptz,
  primary key(request_id,event)
);
alter table public.line_mock_events enable row level security;
revoke all on public.line_mock_events from public,anon,authenticated;
grant select on public.line_mock_events to authenticated;
create policy line_actor on public.line_mock_events for select to authenticated
 using(actor_id=app.current_employee_id() and exists(select 1 from public.drawing_requests r where r.id=request_id));

create function app.capture_line_event() returns trigger language plpgsql security definer set search_path='' as $$
declare kind text; body text;
begin
  if new.from_status='DRAFT' and new.to_status='PENDING_DEPT_REVIEW' then kind:='initial';
  elsif new.from_status='PENDING_ISSUE' and new.to_status='PENDING_RECEIPT' then kind:='issue';
  else return new; end if;
  select format(E'【SUCOOT 圖面%s通知】\n案件編號：%s\n案件狀態：%s\n作業時間（台灣）：%s\n申請人：%s\n部門：%s\n優先順序：%s\n產品明細：\n%s',
    case kind when 'initial' then '首次申請' else '發行' end,r.request_no,
    case kind when 'initial' then '第一層待審' else '待整案簽收' end,
    to_char(new.created_at at time zone 'Asia/Taipei','YYYY-MM-DD HH24:MI:SS'),e.name,d.name,
    case when bool_or(i.is_urgent) then '急件' else '一般件' end,
    string_agg(format('%s. %s｜%s',i.line_no,i.drawing_no,i.drawing_name),E'\n' order by i.line_no))
    into body from public.drawing_requests r join public.employees e on e.id=r.applicant_id
    join public.departments d on d.id=r.department_id join public.drawing_request_items i on i.request_id=r.id
    where r.id=new.request_id group by r.request_no,e.name,d.name;
  insert into public.line_mock_events(request_id,event,actor_id,message)
    values(new.request_id,kind,new.actor_id,body);
  return new;
end $$;
revoke all on function app.capture_line_event() from public,anon,authenticated;
create trigger capture_line_event after insert on public.request_status_history
for each row execute function app.capture_line_event();

create function public.simulate_line_event(p_id uuid,p_event text) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid := app.require_employee();
begin
  update public.line_mock_events set simulated_at=coalesce(simulated_at,now())
   where request_id=p_id and event=p_event and actor_id=actor;
  if not found then perform app.err('FORBIDDEN','無可操作的通知事件'); end if;
end $$;
revoke all on function public.simulate_line_event(uuid,text) from public,anon;
grant execute on function public.simulate_line_event(uuid,text) to authenticated;
