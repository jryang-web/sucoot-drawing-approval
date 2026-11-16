-- SUCOOT V5.7 | 0003 圖面申請、雙層審核、發行、簽收、異常補發、代理、移交

create type public.request_status as enum (
  'DRAFT','PENDING_DEPT_REVIEW','PENDING_DRAWING_REVIEW','PENDING_ISSUE',
  'PENDING_RECEIPT','ISSUE_ABNORMAL','COMPLETED','RETURNED','REJECTED','CANCELLED');
create type public.review_action as enum ('APPROVE','RETURN','REJECT');

create sequence public.request_no_seq;

create table public.drawing_requests (
  id               uuid primary key default gen_random_uuid(),
  request_no       text not null unique,
  applicant_id     uuid not null references public.employees(id),   -- 原申請人（不變）
  owner_id         uuid not null references public.employees(id),   -- 目前簽收負責人（E06 可移交）
  department_id    uuid not null references public.departments(id), -- 送出時部門快照
  status           public.request_status not null default 'DRAFT',
  round            int not null default 0,
  version          int not null default 0,
  note             text,
  returned_level   smallint,
  submitted_at     timestamptz,
  issued_at        timestamptz,
  receipt_due_date date,
  completed_at     timestamptz,
  cancelled_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index drawing_requests_status_idx on public.drawing_requests (status);
create index drawing_requests_applicant_idx on public.drawing_requests (applicant_id);
create index drawing_requests_owner_idx on public.drawing_requests (owner_id);
create index drawing_requests_dept_idx on public.drawing_requests (department_id);

create table public.drawing_request_items (
  id                 uuid primary key default gen_random_uuid(),
  request_id         uuid not null references public.drawing_requests(id) on delete cascade,
  line_no            int not null,
  drawing_no         text not null check (length(btrim(drawing_no)) between 1 and 100),
  drawing_name       text not null check (length(btrim(drawing_name)) between 1 and 200),
  revision           text,
  purpose            text not null check (length(btrim(purpose)) between 1 and 500),
  needed_date        date not null,
  is_urgent          boolean not null default false,
  urgency_reason     text,
  remark             text,
  downgraded_by      uuid references public.employees(id),
  downgrade_reason   text,
  receipt_status     text not null default 'PENDING' check (receipt_status in ('PENDING','RECEIVED','ABNORMAL')),
  unique (request_id, line_no),
  check (not is_urgent or length(btrim(coalesce(urgency_reason,''))) > 0)
);

create table public.request_revisions (
  request_id    uuid not null references public.drawing_requests(id),
  round         int not null,
  snapshot      jsonb not null,
  resubmit_note text,
  submitted_by  uuid not null references public.employees(id),
  submitted_at  timestamptz not null default now(),
  primary key (request_id, round)
);

create table public.review_delegations (
  id           uuid primary key default gen_random_uuid(),
  principal_id uuid not null references public.employees(id),
  delegate_id  uuid not null references public.employees(id),
  level        smallint not null check (level in (1,2)),
  valid_from   date not null,
  valid_to     date not null,
  reason       text not null,
  created_by   uuid not null references public.employees(id),
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  revoked_by   uuid references public.employees(id),
  revoke_reason text,
  check (principal_id <> delegate_id),
  check (valid_to >= valid_from and valid_to - valid_from <= 30)
);

create table public.review_records (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid not null references public.drawing_requests(id),
  round           int not null,
  level           smallint not null check (level in (1,2)),
  action          public.review_action not null,
  reviewer_id     uuid not null references public.employees(id),   -- 實際審核者
  delegation_id   uuid references public.review_delegations(id),
  on_behalf_of_id uuid references public.employees(id),
  comment         text,
  is_effective    boolean not null default true,
  created_at      timestamptz not null default now()
);
create unique index review_records_one_decision
  on public.review_records (request_id, round, level) where is_effective;

create table public.request_status_history (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.drawing_requests(id),
  from_status public.request_status,
  to_status   public.request_status not null,
  actor_id    uuid references public.employees(id),
  reason      text,
  created_at  timestamptz not null default now()
);
create index request_status_history_req_idx on public.request_status_history (request_id, id);

create table public.issue_claims (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null references public.drawing_requests(id),
  staff_id       uuid not null references public.employees(id),
  claimed_at     timestamptz not null default now(),
  released_at    timestamptz,
  released_by    uuid references public.employees(id),
  release_reason text,
  reassigned_to  uuid references public.employees(id)
);
create unique index issue_claims_one_active on public.issue_claims (request_id) where released_at is null;

create table public.item_abnormal_reports (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.drawing_requests(id),
  item_id      uuid not null references public.drawing_request_items(id),
  reported_by  uuid not null references public.employees(id),
  reason       text not null,
  status       text not null default 'OPEN' check (status in ('OPEN','REISSUED','CONFIRMED')),
  reported_at  timestamptz not null default now(),
  reissued_at  timestamptz,
  confirmed_at timestamptz,
  confirmed_by uuid references public.employees(id)
);
create unique index item_abnormal_one_open on public.item_abnormal_reports (item_id) where status <> 'CONFIRMED';

create table public.issue_records (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.drawing_requests(id),
  item_id     uuid not null references public.drawing_request_items(id),
  kind        text not null check (kind in ('INITIAL','REISSUE')),
  abnormal_id uuid references public.item_abnormal_reports(id),
  issued_by   uuid not null references public.employees(id),
  line_note   text,
  issued_at   timestamptz not null default now()
);

create table public.receipt_records (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.drawing_requests(id),
  item_id     uuid references public.drawing_request_items(id),
  kind        text not null check (kind in ('FULL','ITEM_CONFIRM')),
  receiver_id uuid not null references public.employees(id),
  created_at  timestamptz not null default now()
);

create table public.ownership_transfers (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null references public.drawing_requests(id),
  from_owner_id  uuid not null references public.employees(id),
  to_owner_id    uuid not null references public.employees(id),
  reason         text not null,
  transferred_by uuid not null references public.employees(id),
  created_at     timestamptz not null default now()
);

-- 歷史表不可修改／刪除
create trigger request_status_history_immutable before update or delete on public.request_status_history
  for each row execute function app.forbid_change();
create trigger issue_records_immutable before update or delete on public.issue_records
  for each row execute function app.forbid_change();
create trigger receipt_records_immutable before update or delete on public.receipt_records
  for each row execute function app.forbid_change();
create trigger ownership_transfers_immutable before update or delete on public.ownership_transfers
  for each row execute function app.forbid_change();
create trigger request_revisions_immutable before update or delete on public.request_revisions
  for each row execute function app.forbid_change();

-- 審核紀錄：只允許 is_effective true -> false（R04 重送時失效），其他欄位不可改、不可刪
create or replace function app.review_records_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'IMMUTABLE: 審核紀錄不可刪除' using errcode = 'P0001'; end if;
  if (to_jsonb(new) - 'is_effective') <> (to_jsonb(old) - 'is_effective')
     or (old.is_effective = false and new.is_effective = true) then
    raise exception 'IMMUTABLE: 審核紀錄不可修改' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger review_records_guard before update or delete on public.review_records
  for each row execute function app.review_records_guard();

do $$
declare t text;
begin
  foreach t in array array['drawing_requests','drawing_request_items','request_revisions','review_delegations',
    'review_records','request_status_history','issue_claims','item_abnormal_reports','issue_records',
    'receipt_records','ownership_transfers'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;
revoke all on sequence public.request_no_seq from anon, authenticated;

-- ================================================================ helpers
create or replace function app.today_tpe() returns date
language sql stable as $$ select (now() at time zone 'Asia/Taipei')::date $$;

-- R05：發行當日不計，只算週一至週五，暫不扣國定假日
create or replace function app.add_business_days(p_start date, p_days int) returns date
language plpgsql immutable as $$
declare d date := p_start; n int := 0;
begin
  while n < p_days loop
    d := d + 1;
    if extract(isodow from d) < 6 then n := n + 1; end if;
  end loop;
  return d;
end $$;

create or replace function app.is_receipt_overdue(p_due date, p_status public.request_status, p_as_of date)
returns boolean language sql immutable as $$
  select p_due is not null and p_status in ('PENDING_RECEIPT','ISSUE_ABNORMAL') and p_as_of > p_due
$$;

-- 第一層審核資格：直接管轄，或有效的第一層代理（回傳 delegation，直接管轄時回傳 null）
create or replace function app.l1_authority(p_emp uuid, p_dept uuid, out ok boolean, out delegation_id uuid, out principal_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  ok := false;
  if app.has_role('DEPT_MANAGER', p_emp)
     and exists (select 1 from public.manager_departments where manager_id = p_emp and department_id = p_dept) then
    ok := true; return;
  end if;
  select d.id, d.principal_id into delegation_id, principal_id
    from public.review_delegations d
   where d.delegate_id = p_emp and d.level = 1 and d.revoked_at is null
     and app.today_tpe() between d.valid_from and d.valid_to
     and app.has_role('DEPT_MANAGER', p_emp)
     and exists (select 1 from public.manager_departments m where m.manager_id = d.principal_id and m.department_id = p_dept)
   order by d.created_at limit 1;
  ok := delegation_id is not null;
end $$;

create or replace function app.can_view_request(p_id uuid, p_applicant uuid, p_owner uuid, p_dept uuid,
                                                p_status public.request_status) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := app.current_employee_id();
begin
  if me is null then return false; end if;
  if me in (p_applicant, p_owner) then return true; end if;
  if app.has_role('SYS_ADMIN', me) then return true; end if;
  if p_status <> 'DRAFT' and (app.l1_authority(me, p_dept)).ok then return true; end if;
  if exists (select 1 from public.review_records r where r.request_id = p_id and r.reviewer_id = me) then return true; end if;
  if app.has_role('DRAWING_MANAGER', me) and p_status in
     ('PENDING_DRAWING_REVIEW','PENDING_ISSUE','PENDING_RECEIPT','ISSUE_ABNORMAL','COMPLETED') then return true; end if;
  if app.has_role('DRAWING_STAFF', me) and p_status in
     ('PENDING_ISSUE','PENDING_RECEIPT','ISSUE_ABNORMAL','COMPLETED') then return true; end if;
  if exists (select 1 from public.ownership_transfers t where t.request_id = p_id and t.from_owner_id = me) then return true; end if;
  return false;
end $$;

-- 鎖定案件並檢查版本（防止重複審核／重複結案）
create or replace function app.lock_request(p_id uuid, p_expected_version int) returns public.drawing_requests
language plpgsql security definer set search_path = '' as $$
declare r public.drawing_requests;
begin
  select * into r from public.drawing_requests where id = p_id for update;
  if not found then perform app.err('NOT_FOUND', '案件不存在'); end if;
  if p_expected_version is not null and p_expected_version <> r.version then
    perform app.err('VERSION_CONFLICT', '案件已被其他人更新，請重新整理');
  end if;
  return r;
end $$;

create or replace function app.expect_status(r public.drawing_requests, variadic p_allowed public.request_status[]) returns void
language plpgsql as $$
begin
  if not (r.status = any(p_allowed)) then
    perform app.err('INVALID_STATUS', format('案件目前狀態為 %s，不可執行此操作', r.status));
  end if;
end $$;

create or replace function app.set_status(p_id uuid, p_to public.request_status, p_actor uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_from public.request_status;
begin
  select status into v_from from public.drawing_requests where id = p_id;
  update public.drawing_requests set status = p_to, version = version + 1, updated_at = now() where id = p_id;
  insert into public.request_status_history (request_id, from_status, to_status, actor_id, reason)
  values (p_id, v_from, p_to, p_actor, p_reason);
end $$;

create or replace function app.touch(p_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.drawing_requests set version = version + 1, updated_at = now() where id = p_id
$$;

create or replace function app.request_content(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('note', r.note, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('drawing_no', i.drawing_no, 'drawing_name', i.drawing_name,
      'revision', i.revision, 'purpose', i.purpose, 'needed_date', i.needed_date,
      'is_urgent', i.is_urgent, 'urgency_reason', i.urgency_reason, 'remark', i.remark) order by i.line_no)
    from public.drawing_request_items i where i.request_id = r.id), '[]'))
  from public.drawing_requests r where r.id = p_id
$$;

create or replace function app.require_text(p text, p_what text) returns void
language plpgsql as $$
begin
  if p is null or btrim(p) = '' then perform app.err('REASON_REQUIRED', '請填寫' || p_what); end if;
end $$;

-- ================================================================ 階段 1：申請
create or replace function public.save_draft(p_request_id uuid, p_note text, p_items jsonb, p_expected_version int default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; v_id uuid; it jsonb; n int := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'array' then perform app.err('INVALID_INPUT', 'items 必須為陣列'); end if;
  if p_request_id is null then
    insert into public.drawing_requests (request_no, applicant_id, owner_id, department_id, note)
    select 'DR' || to_char(app.today_tpe(), 'YYYYMMDD') || '-' || lpad(nextval('public.request_no_seq')::text, 5, '0'),
           me, me, e.department_id, p_note
      from public.employees e where e.id = me
    returning id into v_id;
    insert into public.request_status_history (request_id, from_status, to_status, actor_id, reason)
    values (v_id, null, 'DRAFT', me, '建立草稿');
  else
    r := app.lock_request(p_request_id, p_expected_version);
    if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能修改自己的申請'); end if;
    perform app.expect_status(r, 'DRAFT', 'RETURNED');
    v_id := r.id;
    update public.drawing_requests set note = p_note where id = v_id;
    delete from public.drawing_request_items where request_id = v_id;
    perform app.touch(v_id);
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    if coalesce((it->>'is_urgent')::boolean, false) and coalesce(btrim(it->>'urgency_reason'), '') = '' then
      perform app.err('URGENCY_REASON_REQUIRED', format('第 %s 筆為急件，請填寫急件原因', n));
    end if;
    insert into public.drawing_request_items (request_id, line_no, drawing_no, drawing_name, revision, purpose,
                                              needed_date, is_urgent, urgency_reason, remark)
    values (v_id, n, btrim(it->>'drawing_no'), btrim(it->>'drawing_name'), nullif(btrim(it->>'revision'), ''),
            btrim(it->>'purpose'), (it->>'needed_date')::date, coalesce((it->>'is_urgent')::boolean, false),
            nullif(btrim(it->>'urgency_reason'), ''), nullif(btrim(it->>'remark'), ''));
  end loop;
  return v_id;
exception when not_null_violation or check_violation or invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
  perform app.err('INVALID_INPUT', '圖號、圖名、申請用途、需求日期為必填');
end $$;

create or replace function public.submit_request(p_id uuid, p_expected_version int default null, p_resubmit_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; v_content jsonb; v_prev jsonb;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能送出自己的申請'); end if;
  perform app.expect_status(r, 'DRAFT', 'RETURNED');
  if not exists (select 1 from public.drawing_request_items where request_id = p_id) then
    perform app.err('NO_ITEMS', '至少需要一筆圖號');
  end if;
  v_content := app.request_content(p_id);

  if r.status = 'RETURNED' then
    select snapshot into v_prev from public.request_revisions where request_id = p_id and round = r.round;
    -- E02：退回後未修改內容，必須填寫回覆說明
    if v_prev = v_content and coalesce(btrim(p_resubmit_note), '') = '' then
      perform app.err('RESUBMIT_NOTE_REQUIRED', '內容未修改，重新送出時必須填寫回覆說明');
    end if;
    -- R03/R04：舊核准保留但失效，重新從第一層開始
    update public.review_records set is_effective = false where request_id = p_id and is_effective;
  end if;

  update public.drawing_requests
     set round = round + 1, submitted_at = now(), returned_level = null,
         department_id = (select department_id from public.employees where id = me)
   where id = p_id;
  insert into public.request_revisions (request_id, round, snapshot, resubmit_note, submitted_by)
  values (p_id, r.round + 1, v_content, nullif(btrim(p_resubmit_note), ''), me);
  perform app.set_status(p_id, 'PENDING_DEPT_REVIEW',
                         me, case when r.status = 'RETURNED' then '重新送出：' || coalesce(p_resubmit_note, '') else '送出申請' end);
end $$;

-- E01：第一層核准前可取消（含 RETURNED，見 Q1）；REJECTED 為終態不可取消
create or replace function public.cancel_request(p_id uuid, p_reason text, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.applicant_id <> me or r.owner_id <> me then perform app.err('FORBIDDEN', '只能取消自己的申請'); end if;
  perform app.expect_status(r, 'DRAFT', 'PENDING_DEPT_REVIEW', 'RETURNED');
  update public.drawing_requests set cancelled_at = now() where id = p_id;
  perform app.set_status(p_id, 'CANCELLED', me, coalesce(nullif(btrim(p_reason), ''), '申請人取消'));
end $$;

-- ================================================================ 階段 2：第一層審核
create or replace function public.review_level1(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_downgrades jsonb default null, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; a record; d jsonb;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_DEPT_REVIEW');
  select * into a from app.l1_authority(me, r.department_id);
  if not a.ok then perform app.err('FORBIDDEN', '不具此部門第一層審核權限'); end if;
  if p_action <> 'APPROVE' then perform app.require_text(p_comment, '審核意見'); end if;

  -- 調降急件（逐筆，須附原因）
  if p_downgrades is not null and jsonb_typeof(p_downgrades) = 'array' then
    for d in select * from jsonb_array_elements(p_downgrades) loop
      perform app.require_text(d->>'reason', '調降急件原因');
      update public.drawing_request_items
         set is_urgent = false, downgraded_by = me, downgrade_reason = btrim(d->>'reason')
       where id = (d->>'item_id')::uuid and request_id = p_id and is_urgent;
      if not found then perform app.err('INVALID_INPUT', '調降的圖號不存在或不是急件'); end if;
    end loop;
  end if;

  insert into public.review_records (request_id, round, level, action, reviewer_id, delegation_id, on_behalf_of_id, comment)
  values (p_id, r.round, 1, p_action, me, a.delegation_id, a.principal_id, p_comment);

  if p_action = 'APPROVE' then
    perform app.set_status(p_id, 'PENDING_DRAWING_REVIEW', me, '第一層核准');
  elsif p_action = 'RETURN' then
    update public.drawing_requests set returned_level = 1 where id = p_id;
    perform app.set_status(p_id, 'RETURNED', me, '第一層退回：' || p_comment);
  else
    perform app.set_status(p_id, 'REJECTED', me, '第一層拒絕：' || p_comment);
  end if;
end $$;

-- ================================================================ 階段 3：第二層審核
create or replace function public.review_level2(p_id uuid, p_action public.review_action, p_comment text default null,
                                                p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_MANAGER'); r public.drawing_requests; v_l1 uuid; v_del_id uuid; v_del_principal uuid;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_DRAWING_REVIEW');
  select reviewer_id into v_l1 from public.review_records
   where request_id = p_id and round = r.round and level = 1 and action = 'APPROVE' and is_effective;
  if v_l1 is null then perform app.err('LEVEL1_REQUIRED', '尚未完成第一層核准'); end if;
  if v_l1 = me then perform app.err('SAME_REVIEWER', '第一層與第二層審核者不得為同一人'); end if;
  if p_action <> 'APPROVE' then perform app.require_text(p_comment, '審核意見'); end if;

  select d.id, d.principal_id into v_del_id, v_del_principal from public.review_delegations d
   where d.delegate_id = me and d.level = 2 and d.revoked_at is null
     and app.today_tpe() between d.valid_from and d.valid_to
   order by d.created_at limit 1;

  insert into public.review_records (request_id, round, level, action, reviewer_id, delegation_id, on_behalf_of_id, comment)
  values (p_id, r.round, 2, p_action, me, v_del_id, v_del_principal, p_comment);

  if p_action = 'APPROVE' then
    perform app.set_status(p_id, 'PENDING_ISSUE', me, '第二層核准');
  elsif p_action = 'RETURN' then
    update public.drawing_requests set returned_level = 2 where id = p_id;
    perform app.set_status(p_id, 'RETURNED', me, '第二層退回：' || p_comment);
  else
    perform app.set_status(p_id, 'REJECTED', me, '第二層拒絕：' || p_comment);
  end if;
end $$;

-- ================================================================ 階段 4：圖管認領與發行
create or replace function public.claim_issue(p_id uuid, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_STAFF'); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_ISSUE');
  if exists (select 1 from public.issue_claims where request_id = p_id and released_at is null) then
    perform app.err('ALREADY_CLAIMED', '此案件已被認領');
  end if;
  insert into public.issue_claims (request_id, staff_id) values (p_id, me);
  perform app.touch(p_id);
end $$;

create or replace function public.record_issue(p_id uuid, p_line_note text default null, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_STAFF'); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  perform app.expect_status(r, 'PENDING_ISSUE');
  if not exists (select 1 from public.issue_claims where request_id = p_id and released_at is null and staff_id = me) then
    perform app.err('NOT_CLAIMED', '請先認領此案件');
  end if;
  if (select count(distinct level) from public.review_records
       where request_id = p_id and round = r.round and action = 'APPROVE' and is_effective) <> 2 then
    perform app.err('NOT_APPROVED', '案件未完成兩層核准，不可發行');
  end if;
  insert into public.issue_records (request_id, item_id, kind, issued_by, line_note)
    select p_id, i.id, 'INITIAL', me, p_line_note from public.drawing_request_items i where i.request_id = p_id;
  update public.drawing_requests
     set issued_at = now(), receipt_due_date = app.add_business_days(app.today_tpe(), 3)
   where id = p_id;
  perform app.set_status(p_id, 'PENDING_RECEIPT', me, '圖面已發行（LINE 群組）');
end $$;

-- ================================================================ 階段 5：簽收與異常
create or replace function public.confirm_receipt(p_id uuid, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.owner_id <> me then perform app.err('FORBIDDEN', '只有案件負責人可以簽收'); end if;
  perform app.expect_status(r, 'PENDING_RECEIPT');
  if exists (select 1 from public.item_abnormal_reports where request_id = p_id and status <> 'CONFIRMED') then
    perform app.err('ABNORMAL_PENDING', '尚有異常圖號未完成補發確認');
  end if;
  update public.drawing_request_items set receipt_status = 'RECEIVED' where request_id = p_id and receipt_status = 'PENDING';
  insert into public.receipt_records (request_id, kind, receiver_id) values (p_id, 'FULL', me);
  update public.drawing_requests set completed_at = now() where id = p_id;
  perform app.set_status(p_id, 'COMPLETED', me, '整案簽收');
end $$;

create or replace function public.report_abnormal(p_id uuid, p_items jsonb, p_expected_version int default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); r public.drawing_requests; it jsonb;
begin
  r := app.lock_request(p_id, p_expected_version);
  if r.owner_id <> me then perform app.err('FORBIDDEN', '只有案件負責人可以回報異常'); end if;
  perform app.expect_status(r, 'PENDING_RECEIPT', 'ISSUE_ABNORMAL');
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    perform app.err('INVALID_INPUT', '請選擇異常圖號');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    perform app.require_text(it->>'reason', '異常原因');
    if not exists (select 1 from public.drawing_request_items where id = (it->>'item_id')::uuid and request_id = p_id) then
      perform app.err('INVALID_INPUT', '圖號不屬於此案件');
    end if;
    begin
      insert into public.item_abnormal_reports (request_id, item_id, reported_by, reason)
      values (p_id, (it->>'item_id')::uuid, me, btrim(it->>'reason'));
    exception when unique_violation then
      perform app.err('ABNORMAL_EXISTS', '此圖號已有處理中的異常');
    end;
    update public.drawing_request_items set receipt_status = 'ABNORMAL' where id = (it->>'item_id')::uuid;
  end loop;
  if r.status = 'PENDING_RECEIPT' then
    perform app.set_status(p_id, 'ISSUE_ABNORMAL', me, '回報圖號異常');
  else
    perform app.touch(p_id);
  end if;
end $$;

-- E05：只補發異常圖號；Q3：補發後簽收期限重新計算
create or replace function public.reissue_item(p_abnormal_id uuid, p_line_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('DRAWING_STAFF'); a public.item_abnormal_reports; r public.drawing_requests;
begin
  select * into a from public.item_abnormal_reports where id = p_abnormal_id;
  if not found then perform app.err('NOT_FOUND', '異常紀錄不存在'); end if;
  r := app.lock_request(a.request_id, null);
  perform app.expect_status(r, 'ISSUE_ABNORMAL');
  select * into a from public.item_abnormal_reports where id = p_abnormal_id for update;
  if a.status <> 'OPEN' then perform app.err('INVALID_STATUS', '此異常已補發'); end if;
  insert into public.issue_records (request_id, item_id, kind, abnormal_id, issued_by, line_note)
  values (a.request_id, a.item_id, 'REISSUE', a.id, me, p_line_note);
  update public.item_abnormal_reports set status = 'REISSUED', reissued_at = now() where id = a.id;
  update public.drawing_requests set receipt_due_date = app.add_business_days(app.today_tpe(), 3) where id = a.request_id;
  perform app.touch(a.request_id);
end $$;

create or replace function public.confirm_reissued_item(p_abnormal_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_employee(); a public.item_abnormal_reports; r public.drawing_requests;
begin
  select * into a from public.item_abnormal_reports where id = p_abnormal_id;
  if not found then perform app.err('NOT_FOUND', '異常紀錄不存在'); end if;
  r := app.lock_request(a.request_id, null);
  if r.owner_id <> me then perform app.err('FORBIDDEN', '只有案件負責人可以確認'); end if;
  perform app.expect_status(r, 'ISSUE_ABNORMAL');
  select * into a from public.item_abnormal_reports where id = p_abnormal_id for update;
  if a.status <> 'REISSUED' then perform app.err('INVALID_STATUS', '此圖號尚未補發'); end if;
  update public.item_abnormal_reports set status = 'CONFIRMED', confirmed_at = now(), confirmed_by = me where id = a.id;
  update public.drawing_request_items set receipt_status = 'RECEIVED' where id = a.item_id;
  insert into public.receipt_records (request_id, item_id, kind, receiver_id) values (a.request_id, a.item_id, 'ITEM_CONFIRM', me);
  if not exists (select 1 from public.item_abnormal_reports where request_id = a.request_id and status <> 'CONFIRMED') then
    perform app.set_status(a.request_id, 'PENDING_RECEIPT', me, '異常圖號均已補發確認');
  else
    perform app.touch(a.request_id);
  end if;
end $$;

-- ================================================================ 管理員例外處理
-- E03 代理審核（Q2：起訖日必填、最長 30 天、同一被代理人同層同時間僅一位代理）
create or replace function public.admin_create_delegation(p_principal uuid, p_delegate uuid, p_level smallint,
                                                          p_valid_from date, p_valid_to date, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('SYS_ADMIN'); v_role public.app_role; v_id uuid;
begin
  perform app.require_text(p_reason, '代理原因');
  v_role := case p_level when 1 then 'DEPT_MANAGER'::public.app_role when 2 then 'DRAWING_MANAGER'::public.app_role end;
  if v_role is null then perform app.err('INVALID_INPUT', 'level 必須為 1 或 2'); end if;
  if not app.has_role(v_role, p_principal) then perform app.err('INVALID_PRINCIPAL', '被代理人不具該層審核角色'); end if;
  if not app.has_role(v_role, p_delegate) then perform app.err('INVALID_DELEGATE', '代理人須具備相同審核角色且為啟用中'); end if;
  if p_valid_to < p_valid_from or p_valid_to - p_valid_from > 30 then
    perform app.err('INVALID_PERIOD', '代理期間須為 1–31 天（起訖含當日，最長 30 天差距）');
  end if;
  if exists (select 1 from public.review_delegations d where d.principal_id = p_principal and d.level = p_level
             and d.revoked_at is null and daterange(d.valid_from, d.valid_to, '[]') && daterange(p_valid_from, p_valid_to, '[]')) then
    perform app.err('DELEGATION_OVERLAP', '此期間已有代理設定');
  end if;
  insert into public.review_delegations (principal_id, delegate_id, level, valid_from, valid_to, reason, created_by)
  values (p_principal, p_delegate, p_level, p_valid_from, p_valid_to, btrim(p_reason), me) returning id into v_id;
  perform app.audit(me, 'DELEGATION_CREATE', 'review_delegation', v_id::text, null,
                    (select to_jsonb(d) from public.review_delegations d where d.id = v_id), p_reason);
  return v_id;
end $$;

create or replace function public.admin_revoke_delegation(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('SYS_ADMIN');
begin
  perform app.require_text(p_reason, '撤銷原因');
  update public.review_delegations set revoked_at = now(), revoked_by = me, revoke_reason = p_reason
   where id = p_id and revoked_at is null;
  if not found then perform app.err('NOT_FOUND', '代理設定不存在或已撤銷'); end if;
  perform app.audit(me, 'DELEGATION_REVOKE', 'review_delegation', p_id::text, null, null, p_reason);
end $$;

-- E04 解除認領／重新指派
create or replace function public.admin_release_claim(p_id uuid, p_reason text, p_reassign_to uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('SYS_ADMIN'); r public.drawing_requests; c public.issue_claims;
begin
  perform app.require_text(p_reason, '原因');
  r := app.lock_request(p_id, null);
  perform app.expect_status(r, 'PENDING_ISSUE');
  select * into c from public.issue_claims where request_id = p_id and released_at is null for update;
  if not found then perform app.err('NOT_CLAIMED', '此案件目前沒有認領人'); end if;
  if p_reassign_to is not null then
    if not app.has_role('DRAWING_STAFF', p_reassign_to) then perform app.err('INVALID_STAFF', '接手人須為啟用中的圖管人員'); end if;
    if p_reassign_to = c.staff_id then perform app.err('INVALID_STAFF', '接手人與原認領人相同'); end if;
  end if;
  update public.issue_claims set released_at = now(), released_by = me, release_reason = p_reason, reassigned_to = p_reassign_to
   where id = c.id;
  if p_reassign_to is not null then
    insert into public.issue_claims (request_id, staff_id) values (p_id, p_reassign_to);
  end if;
  perform app.touch(p_id);
  perform app.audit(me, case when p_reassign_to is null then 'CLAIM_RELEASE' else 'CLAIM_REASSIGN' end, 'drawing_request', p_id::text,
                    jsonb_build_object('staff_id', c.staff_id), jsonb_build_object('staff_id', p_reassign_to), p_reason);
end $$;

-- E06 移交簽收負責人（原申請人保留）
create or replace function public.admin_transfer_owner(p_id uuid, p_to uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := app.require_role('SYS_ADMIN'); r public.drawing_requests;
begin
  perform app.require_text(p_reason, '移交原因');
  r := app.lock_request(p_id, null);
  if r.status in ('COMPLETED','REJECTED','CANCELLED') then perform app.err('INVALID_STATUS', '已結束的案件不可移交'); end if;
  if not exists (select 1 from public.employees where id = p_to and is_active) then
    perform app.err('INVALID_OWNER', '新負責人須為啟用中的員工');
  end if;
  if p_to = r.owner_id then perform app.err('INVALID_OWNER', '新負責人與目前負責人相同'); end if;
  insert into public.ownership_transfers (request_id, from_owner_id, to_owner_id, reason, transferred_by)
  values (p_id, r.owner_id, p_to, p_reason, me);
  update public.drawing_requests set owner_id = p_to where id = p_id;
  perform app.touch(p_id);
  perform app.audit(me, 'OWNER_TRANSFER', 'drawing_request', p_id::text,
                    jsonb_build_object('owner_id', r.owner_id), jsonb_build_object('owner_id', p_to), p_reason);
end $$;

-- 管理者警示：無人可審／無人可發行（D2–D4）
create or replace function public.admin_alerts() returns table (request_id uuid, request_no text, status public.request_status, problem text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_role('SYS_ADMIN');
  return query
  select r.id, r.request_no, r.status, '此部門沒有可審核的第一層主管'::text
    from public.drawing_requests r
   where r.status = 'PENDING_DEPT_REVIEW'
     and not exists (select 1 from public.employees e where e.is_active and (app.l1_authority(e.id, r.department_id)).ok)
  union all
  select r.id, r.request_no, r.status, '沒有可執行第二層審核的圖管主管（須與第一層不同人）'::text
    from public.drawing_requests r
   where r.status = 'PENDING_DRAWING_REVIEW'
     and not exists (select 1 from public.employee_roles er join public.employees e on e.id = er.employee_id
                     where er.role = 'DRAWING_MANAGER' and e.is_active
                       and e.id <> (select rr.reviewer_id from public.review_records rr where rr.request_id = r.id
                                     and rr.round = r.round and rr.level = 1 and rr.is_effective))
  union all
  select r.id, r.request_no, r.status, '沒有啟用中的圖管人員或認領人已停用'::text
    from public.drawing_requests r
   where r.status in ('PENDING_ISSUE','ISSUE_ABNORMAL')
     and (not exists (select 1 from public.employee_roles er join public.employees e on e.id = er.employee_id
                      where er.role = 'DRAWING_STAFF' and e.is_active)
          or exists (select 1 from public.issue_claims c join public.employees e on e.id = c.staff_id
                     where c.request_id = r.id and c.released_at is null and not e.is_active))
  union all
  select r.id, r.request_no, r.status, '案件負責人帳號已停用，需移交'::text
    from public.drawing_requests r join public.employees e on e.id = r.owner_id
   where not e.is_active and r.status not in ('COMPLETED','REJECTED','CANCELLED');
end $$;

-- 測試用純函式（不涉及資料）
create or replace function public.calc_receipt_due(p_issue_date date) returns date
language sql immutable as $$ select app.add_business_days(p_issue_date, 3) $$;
create or replace function public.calc_is_overdue(p_due date, p_status public.request_status, p_as_of date) returns boolean
language sql immutable as $$ select app.is_receipt_overdue(p_due, p_status, p_as_of) $$;

-- ================================================================ 查詢 view（含逾期標記）
create view public.v_requests with (security_invoker = true) as
select r.*,
       app.is_receipt_overdue(r.receipt_due_date, r.status, app.today_tpe()) as is_receipt_overdue,
       a.employee_no as applicant_no, a.name as applicant_name,
       o.employee_no as owner_no, o.name as owner_name,
       d.name as department_name,
       (select count(*) from public.drawing_request_items i where i.request_id = r.id) as item_count,
       (select bool_or(i.is_urgent) from public.drawing_request_items i where i.request_id = r.id) as is_urgent,
       (select c.staff_id from public.issue_claims c where c.request_id = r.id and c.released_at is null) as claimed_by
  from public.drawing_requests r
  join public.employees a on a.id = r.applicant_id
  join public.employees o on o.id = r.owner_id
  join public.departments d on d.id = r.department_id;
revoke all on public.v_requests from anon;
grant select on public.v_requests to authenticated;

-- ================================================================ RLS
create policy drawing_requests_select on public.drawing_requests for select to authenticated
  using (app.can_view_request(id, applicant_id, owner_id, department_id, status));
do $$
declare t text;
begin
  foreach t in array array['drawing_request_items','request_revisions','review_records','request_status_history',
    'issue_claims','item_abnormal_reports','issue_records','receipt_records','ownership_transfers'] loop
    execute format('create policy %I on public.%I for select to authenticated
                    using (exists (select 1 from public.drawing_requests r where r.id = request_id))', t || '_select', t);
  end loop;
end $$;
create policy review_delegations_select on public.review_delegations for select to authenticated
  using (app.has_role('SYS_ADMIN') or app.current_employee_id() in (principal_id, delegate_id));

-- ================================================================ 權限
grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function app.set_status(uuid,public.request_status,uuid,text) from authenticated;
revoke execute on function app.touch(uuid) from authenticated;
revoke execute on function app.lock_request(uuid,int) from authenticated;
revoke execute on function app.audit(uuid,text,text,text,jsonb,jsonb,text) from authenticated;
revoke execute on function app.set_roles(uuid,uuid,public.app_role[],text) from authenticated;
revoke execute on function app.set_manager_departments(uuid,uuid,uuid[],text) from authenticated;

grant execute on function public.save_draft(uuid,text,jsonb,int) to authenticated;
grant execute on function public.submit_request(uuid,int,text) to authenticated;
grant execute on function public.cancel_request(uuid,text,int) to authenticated;
grant execute on function public.review_level1(uuid,public.review_action,text,jsonb,int) to authenticated;
grant execute on function public.review_level2(uuid,public.review_action,text,int) to authenticated;
grant execute on function public.claim_issue(uuid,int) to authenticated;
grant execute on function public.record_issue(uuid,text,int) to authenticated;
grant execute on function public.confirm_receipt(uuid,int) to authenticated;
grant execute on function public.report_abnormal(uuid,jsonb,int) to authenticated;
grant execute on function public.reissue_item(uuid,text) to authenticated;
grant execute on function public.confirm_reissued_item(uuid) to authenticated;
grant execute on function public.admin_create_delegation(uuid,uuid,smallint,date,date,text) to authenticated;
grant execute on function public.admin_revoke_delegation(uuid,text) to authenticated;
grant execute on function public.admin_release_claim(uuid,text,uuid) to authenticated;
grant execute on function public.admin_transfer_owner(uuid,uuid,text) to authenticated;
grant execute on function public.admin_alerts() to authenticated;
grant execute on function public.calc_receipt_due(date) to authenticated;
grant execute on function public.calc_is_overdue(date,public.request_status,date) to authenticated;
