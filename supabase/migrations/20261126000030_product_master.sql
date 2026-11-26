-- SUCOOT V5.9 | 產品主檔：員工智慧搜尋＋管理員 Excel 完整同步（兩階段：預覽 → 確認）
-- 原則：
--   * 產品編碼以文字保存，大小寫視為不同（與 V5.8 規則一致），只清除前後空白。
--   * 員工只能透過 search_products 查詢啟用中的產品；不開放資料表直接讀寫。
--   * 只有 SYS_ADMIN 能預覽與執行匯入，權限一律在後端驗證。
--   * 正式同步在單一交易內完成（全部成功或全部回滾），並以 advisory lock＋主檔版本號防止並發不一致。
--   * 從不刪除產品；未出現在新 Excel 的編碼改為停用。
--   * 案件明細保存送出當下的文字（drawing_no／drawing_name），主檔更新不會改寫歷史案件。

create extension if not exists pg_trgm with schema extensions;

-- ================================================================ 資料表
create table public.products (
  code            text primary key check (length(code) between 1 and 30 and code = btrim(code) and code !~ '[[:cntrl:][:space:]]'),
  name            text not null check (length(name) between 1 and 200 and name = btrim(name)),
  spec            text not null default '' check (length(spec) <= 200 and spec = btrim(spec)),
  is_active       boolean not null default true,
  search_text     text generated always as (lower(normalize(code || ' ' || name || ' ' || spec, NFKC))) stored,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deactivated_at  timestamptz,
  last_batch_id   uuid
);
create index products_active_code_idx on public.products (code) where is_active;
create index products_search_trgm_idx on public.products using gin (search_text extensions.gin_trgm_ops);

-- 主檔版本：每次正式同步 +1；預覽時記錄，提交時比對，不同即拒絕（須重新預覽）
create table public.product_master_state (
  id        boolean primary key default true check (id),
  version   bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.product_master_state default values;

create table public.product_import_batches (
  id               uuid primary key default gen_random_uuid(),
  file_name        text not null,
  file_sha256      text,
  status           text not null default 'PREVIEWED' check (status in ('PREVIEWED','REJECTED','COMMITTED')),
  base_version     bigint not null,
  total_rows       int not null,
  added            int not null default 0,
  updated          int not null default 0,
  unchanged        int not null default 0,
  reactivated      int not null default 0,
  deactivated      int not null default 0,
  error_count      int not null default 0,
  errors           jsonb not null default '[]',
  warnings         jsonb not null default '[]',
  active_before    int not null default 0,
  high_risk        boolean not null default false,
  created_by       uuid not null references public.employees(id),
  created_at       timestamptz not null default now(),
  committed_by     uuid references public.employees(id),
  committed_at     timestamptz,
  high_risk_confirmed boolean not null default false
);
create index product_import_batches_created_idx on public.product_import_batches (created_at desc);

-- 預覽時暫存的已清理資料；正式同步只使用這份資料（確保「預覽的內容＝寫入的內容」）
create table public.product_import_rows (
  batch_id uuid not null references public.product_import_batches(id) on delete cascade,
  row_no   int not null,
  code     text not null,
  name     text not null,
  spec     text not null,
  primary key (batch_id, code)
);

alter table public.products enable row level security;
alter table public.product_master_state enable row level security;
alter table public.product_import_batches enable row level security;
alter table public.product_import_rows enable row level security;
-- 不建立任何 policy、不授予任何資料表權限：員工與管理員都只能透過下列 RPC 存取
revoke all on public.products, public.product_master_state, public.product_import_batches, public.product_import_rows
  from public, anon, authenticated;

-- ================================================================ 員工：產品搜尋
-- 以空白分隔多個關鍵字（全部須符合），比對編碼／品名／規格（不分大小寫、全形半形視為相同）。
-- 只回傳啟用中產品；依「編碼完全相同（含大小寫）→ 編碼相同（不分大小寫）→ 編碼開頭相同 → 編碼包含 → 其他」排序；
-- 分頁（每頁最多 50 筆）。
create or replace function public.search_products(p_query text, p_limit int default 20, p_offset int default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  raw text := normalize(btrim(coalesce(p_query, '')), NFKC);
  q text := lower(raw);
  terms text[];
  lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
  off int := least(greatest(coalesce(p_offset, 0), 0), 10000);
  rows jsonb;
begin
  perform app.require_employee();
  if q = '' then return jsonb_build_object('items', '[]'::jsonb, 'has_more', false); end if;
  if length(q) > 100 then perform app.err('INVALID_INPUT', '搜尋文字過長'); end if;
  -- 轉義 LIKE 萬用字元，避免使用者輸入的 % _ \ 被當成萬用字元
  select array_agg('%' || replace(replace(replace(t, '\', '\\'), '%', '\%'), '_', '\_') || '%')
    into terms from regexp_split_to_table(q, '\s+') t where t <> '';
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'spec', spec) order by rank, code), '[]')
    into rows
    from (
      select p.code, p.name, p.spec,
             case when normalize(p.code, NFKC) = raw then 0
                  when lower(normalize(p.code, NFKC)) = q then 1
                  when lower(normalize(p.code, NFKC)) like replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%' then 2
                  when lower(normalize(p.code, NFKC)) like terms[1] then 3
                  else 4 end as rank
        from public.products p
       where p.is_active and p.search_text like all (terms)
       order by rank, p.code
       limit lim + 1 offset off
    ) s;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(rows) with ordinality e(x, n) where n <= lim), '[]'),
    'has_more', jsonb_array_length(rows) > lim);
end $$;

-- ================================================================ 管理員：匯入預覽（第一階段）
-- p_header：Excel 第一列欄名；p_rows：[{row, code, name, spec}, ...]（前端只負責讀檔，所有驗證在後端）
create or replace function public.admin_product_import_preview(p_file_name text, p_file_sha256 text,
  p_header jsonb, p_rows jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := app.require_role('SYS_ADMIN');
  b public.product_import_batches;
  errs jsonb := '[]'; warns jsonb := '[]';
  n_err int := 0; missing text[];
begin
  if jsonb_typeof(p_header) is distinct from 'array' then perform app.err('INVALID_INPUT', '缺少欄名列'); end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then perform app.err('INVALID_INPUT', '資料格式錯誤'); end if;
  if jsonb_array_length(p_rows) > 50000 then perform app.err('INVALID_INPUT', '單次匯入最多 50,000 筆'); end if;

  -- 必要欄位
  select array_agg(c) into missing from unnest(array['產品代碼', '品名', '規格']) c
   where not exists (select 1 from jsonb_array_elements_text(p_header) h where btrim(h) = c);
  if missing is not null then
    errs := errs || jsonb_build_object('row', 1, 'code', null, 'message', '缺少必要欄位：' || array_to_string(missing, '、'));
  end if;
  if jsonb_array_length(p_rows) = 0 then
    errs := errs || jsonb_build_object('row', null, 'code', null, 'message', '檔案沒有任何產品資料');
  end if;

  -- 清理（只去除前後空白）並逐列驗證
  create temp table if not exists pg_temp.import_stage (row_no int, code text, name text, spec text, raw_code text) on commit drop;
  truncate pg_temp.import_stage;
  insert into pg_temp.import_stage
  select (x->>'row')::int, btrim(coalesce(x->>'code', '')), btrim(coalesce(x->>'name', '')), btrim(coalesce(x->>'spec', '')), x->>'code'
    from jsonb_array_elements(p_rows) x;

  with bad as (
    select row_no, code,
      case when code = '' then '產品代碼空白'
           when length(code) > 30 then '產品代碼超過 30 字元'
           when code ~ '[[:cntrl:][:space:]]' then '產品代碼含空白或控制字元'
           when name = '' then '品名空白'
           when length(name) > 200 then '品名超過 200 字元'
           when length(spec) > 200 then '規格超過 200 字元'
           when name ~ '[[:cntrl:]]' or spec ~ '[[:cntrl:]]' then '品名或規格含控制字元'
      end as message
    from pg_temp.import_stage
  ), dup as (
    select s.row_no, s.code, '產品代碼重複（另見第 ' || string_agg(o.row_no::text, '、' order by o.row_no) || ' 列）' as message
      from pg_temp.import_stage s join pg_temp.import_stage o on o.code = s.code and o.row_no <> s.row_no and s.code <> ''
     group by s.row_no, s.code
  ), allerr as (
    select * from bad where message is not null union all select * from dup
  )
  select count(*), coalesce(jsonb_agg(jsonb_build_object('row', row_no, 'code', code, 'message', message) order by row_no) filter (where rn <= 500), '[]')
    into n_err, errs
    from (select *, row_number() over (order by row_no) rn from allerr) e;
  -- 合併欄位層級錯誤
  if missing is not null then n_err := n_err + 1; errs := jsonb_build_array(jsonb_build_object('row', 1, 'code', null, 'message', '缺少必要欄位：' || array_to_string(missing, '、'))) || errs; end if;
  if jsonb_array_length(p_rows) = 0 then n_err := n_err + 1; errs := errs || jsonb_build_object('row', null, 'code', null, 'message', '檔案沒有任何產品資料'); end if;

  -- 提醒（不阻擋）：只有大小寫不同的編碼（V5.8 規則視為不同產品）
  select coalesce(jsonb_agg(jsonb_build_object('codes', codes) order by codes[1]), '[]') into warns
    from (select array_agg(code order by code) codes from pg_temp.import_stage where code <> ''
          group by lower(code) having count(distinct code) > 1) w;

  insert into public.product_import_batches (file_name, file_sha256, status, base_version, total_rows, error_count, errors, warnings, created_by)
  values (left(coalesce(nullif(btrim(p_file_name), ''), '未命名.xlsx'), 200), p_file_sha256,
          case when n_err > 0 then 'REJECTED' else 'PREVIEWED' end,
          (select version from public.product_master_state), jsonb_array_length(p_rows), n_err, errs, warns, me)
  returning * into b;

  if n_err = 0 then
    insert into public.product_import_rows (batch_id, row_no, code, name, spec)
    select b.id, row_no, code, name, spec from pg_temp.import_stage;
    update public.product_import_batches t set
      added       = (select count(*) from public.product_import_rows r where r.batch_id = b.id
                       and not exists (select 1 from public.products p where p.code = r.code)),
      reactivated = (select count(*) from public.product_import_rows r join public.products p on p.code = r.code
                       where r.batch_id = b.id and not p.is_active),
      updated     = (select count(*) from public.product_import_rows r join public.products p on p.code = r.code
                       where r.batch_id = b.id and p.is_active and (p.name, p.spec) is distinct from (r.name, r.spec)),
      unchanged   = (select count(*) from public.product_import_rows r join public.products p on p.code = r.code
                       where r.batch_id = b.id and p.is_active and (p.name, p.spec) = (r.name, r.spec)),
      deactivated = (select count(*) from public.products p where p.is_active
                       and not exists (select 1 from public.product_import_rows r where r.batch_id = b.id and r.code = p.code)),
      active_before = (select count(*) from public.products where is_active)
     where t.id = b.id returning * into b;
    -- 預計停用超過現有啟用產品 10%：高風險，須額外確認
    update public.product_import_batches set high_risk = (b.active_before > 0 and b.deactivated * 10 > b.active_before)
     where id = b.id returning * into b;
  end if;

  perform app.audit(me, 'PRODUCT_IMPORT_PREVIEW', 'product_import', b.id::text, null,
    jsonb_build_object('file', b.file_name, 'total', b.total_rows, 'errors', b.error_count, 'added', b.added, 'updated', b.updated,
                       'unchanged', b.unchanged, 'reactivated', b.reactivated, 'deactivated', b.deactivated, 'high_risk', b.high_risk), null);
  return app.product_batch_json(b);
end $$;

create or replace function app.product_batch_json(b public.product_import_batches) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('batch_id', b.id, 'file_name', b.file_name, 'status', b.status, 'total', b.total_rows,
    'added', b.added, 'updated', b.updated, 'unchanged', b.unchanged, 'reactivated', b.reactivated,
    'deactivated', b.deactivated, 'active_before', b.active_before, 'error_count', b.error_count,
    'errors', b.errors, 'warnings', b.warnings, 'high_risk', b.high_risk,
    'can_commit', b.status = 'PREVIEWED' and b.error_count = 0,
    'created_at', b.created_at, 'committed_at', b.committed_at,
    'created_by', (select e.employee_no || ' ' || e.name from public.employees e where e.id = b.created_by),
    'committed_by', (select e.employee_no || ' ' || e.name from public.employees e where e.id = b.committed_by))
$$;

-- ================================================================ 管理員：正式同步（第二階段）
create or replace function public.admin_product_import_commit(p_batch_id uuid, p_confirm_high_risk boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me uuid := app.require_role('SYS_ADMIN');
  b public.product_import_batches; st public.product_master_state;
  n_add int; n_upd int; n_react int; n_deact int;
begin
  -- 同一時間只允許一個正式同步；並鎖定主檔版本列
  perform pg_advisory_xact_lock(hashtext('sucoot.product_master_import'));
  select * into st from public.product_master_state for update;
  select * into b from public.product_import_batches where id = p_batch_id for update;
  if not found then perform app.err('NOT_FOUND', '找不到匯入批次'); end if;
  if b.status = 'COMMITTED' then perform app.err('ALREADY_COMMITTED', '此批次已同步完成'); end if;
  if b.status <> 'PREVIEWED' or b.error_count > 0 then perform app.err('INVALID_BATCH', '此批次有錯誤，不能同步'); end if;
  if b.created_by <> me then perform app.err('FORBIDDEN', '只能確認自己預覽的批次'); end if;
  if b.created_at < now() - interval '60 minutes' then perform app.err('PREVIEW_EXPIRED', '預覽已超過 60 分鐘，請重新上傳預覽'); end if;
  if b.base_version <> st.version then
    perform app.err('STALE_PREVIEW', '預覽後產品主檔已被其他匯入修改，請重新上傳預覽');
  end if;
  if b.high_risk and not coalesce(p_confirm_high_risk, false) then
    perform app.err('HIGH_RISK_CONFIRM_REQUIRED', '預計停用超過現有啟用產品 10%，須額外確認');
  end if;

  -- 新增
  insert into public.products (code, name, spec, last_batch_id)
  select r.code, r.name, r.spec, b.id from public.product_import_rows r
   where r.batch_id = b.id and not exists (select 1 from public.products p where p.code = r.code);
  get diagnostics n_add = row_count;
  -- 重新啟用（同時套用最新品名／規格）
  update public.products p set is_active = true, deactivated_at = null, name = r.name, spec = r.spec,
         updated_at = now(), last_batch_id = b.id
    from public.product_import_rows r where r.batch_id = b.id and r.code = p.code and not p.is_active;
  get diagnostics n_react = row_count;
  -- 更新（資料不同者）
  update public.products p set name = r.name, spec = r.spec, updated_at = now(), last_batch_id = b.id
    from public.product_import_rows r
   where r.batch_id = b.id and r.code = p.code and p.is_active and p.last_batch_id is distinct from b.id
     and (p.name, p.spec) is distinct from (r.name, r.spec);
  get diagnostics n_upd = row_count;
  -- 停用（未列於新 Excel；不刪除）
  update public.products p set is_active = false, deactivated_at = now(), updated_at = now(), last_batch_id = b.id
   where p.is_active and not exists (select 1 from public.product_import_rows r where r.batch_id = b.id and r.code = p.code);
  get diagnostics n_deact = row_count;

  -- 與預覽結果不一致即全部回滾
  if (n_add, n_upd, n_react, n_deact) is distinct from (b.added, b.updated, b.reactivated, b.deactivated) then
    perform app.err('PREVIEW_MISMATCH', '同步結果與預覽不一致，已全部取消');
  end if;

  update public.product_master_state set version = version + 1, updated_at = now();
  update public.product_import_batches set status = 'COMMITTED', committed_by = me, committed_at = now(),
         high_risk_confirmed = b.high_risk
   where id = b.id returning * into b;
  perform app.audit(me, 'PRODUCT_IMPORT_COMMIT', 'product_import', b.id::text, jsonb_build_object('version', st.version),
    jsonb_build_object('version', st.version + 1, 'file', b.file_name, 'total', b.total_rows, 'added', n_add, 'updated', n_upd,
                       'unchanged', b.unchanged, 'reactivated', n_react, 'deactivated', n_deact, 'high_risk_confirmed', b.high_risk), null);
  return app.product_batch_json(b);
end $$;

-- ================================================================ 管理員：主檔統計、批次紀錄、錯誤明細
create or replace function public.admin_product_master_summary() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform app.require_role('SYS_ADMIN');
  return jsonb_build_object(
    'active', (select count(*) from public.products where is_active),
    'inactive', (select count(*) from public.products where not is_active),
    'version', (select version from public.product_master_state),
    'batches', coalesce((select jsonb_agg(app.product_batch_json(b) - 'errors' - 'warnings' order by b.created_at desc)
                         from (select * from public.product_import_batches order by created_at desc limit 20) b), '[]'));
end $$;

-- 管理員檢視主檔（含停用），用於核對；分頁
create or replace function public.admin_search_products(p_query text, p_include_inactive boolean default true,
  p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare q text := lower(normalize(btrim(coalesce(p_query, '')), NFKC)); lim int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform app.require_role('SYS_ADMIN');
  return jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'spec', spec,
      'is_active', is_active, 'updated_at', updated_at) order by code)
    from (select * from public.products p
           where (p_include_inactive or p.is_active)
             and (q = '' or p.search_text like '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%')
           order by p.code limit lim offset greatest(coalesce(p_offset, 0), 0)) s), '[]'));
end $$;

-- ================================================================ V5.8 相容（最小修改）
-- V5.8 手動輸入的產品編碼規則不變（1–30 個英數與 _ . / -）。
-- 另外允許「產品主檔中存在的編碼」（例如含 × 或 " 的正式產品編碼），以便員工選用主檔產品。
create or replace function app.product_code_acceptable(p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_code, '') ~ '^[A-Za-z0-9_./-]{1,30}$'
      or exists (select 1 from public.products p where p.code = p_code)
$$;

create or replace function public.write_r8_application(p_purpose text, p_urgent boolean, p_reason text,
  p_note text, p_products jsonb, p_submit boolean,p_id uuid,p_version int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare request_id uuid; items jsonb;
begin
  if nullif(trim(p_purpose),'') is null or jsonb_typeof(p_products) is distinct from 'array'
    or jsonb_array_length(p_products) not between 1 and 5 then
    raise exception 'INVALID_INPUT: 請填寫用途與一至五筆產品';
  end if;
  if exists (select 1 from jsonb_array_elements(p_products) x where
      not app.product_code_acceptable(trim(x->>'code')) or nullif(trim(x->>'name'),'') is null)
    or (select count(distinct trim(x->>'code')) from jsonb_array_elements(p_products) x) <> jsonb_array_length(p_products)
  then raise exception 'INVALID_INPUT: 請核對產品編碼與品名'; end if;
  perform app.require_employee();
  if p_id is not null and not exists(select 1 from public.drawing_requests r
    where r.id=p_id and r.applicant_id=app.current_employee_id() and r.owner_id=r.applicant_id) then
    perform app.err('FORBIDDEN','只能編輯自己的案件');
  end if;
  select jsonb_agg(jsonb_build_object('drawing_no',x->>'code','drawing_name',x->>'name',
    'revision',old.revision,'needed_date',old.needed_date,'remark',x->>'remark','purpose',p_purpose,'is_urgent',p_urgent,'urgency_reason',p_reason) order by ord)
    into items from jsonb_array_elements(p_products) with ordinality t(x,ord) left join public.drawing_request_items old on old.request_id=p_id and old.drawing_no=trim(x->>'code');
  request_id := public.save_draft(p_id,p_note,items,p_version);
  if p_submit then perform public.submit_request(request_id); end if;
  return request_id;
end $$;

-- ================================================================ 權限
revoke all on function public.search_products(text,int,int) from public, anon;
grant execute on function public.search_products(text,int,int) to authenticated;
revoke all on function public.admin_product_import_preview(text,text,jsonb,jsonb) from public, anon;
grant execute on function public.admin_product_import_preview(text,text,jsonb,jsonb) to authenticated;
revoke all on function public.admin_product_import_commit(uuid,boolean) from public, anon;
grant execute on function public.admin_product_import_commit(uuid,boolean) to authenticated;
revoke all on function public.admin_product_master_summary() from public, anon;
grant execute on function public.admin_product_master_summary() to authenticated;
revoke all on function public.admin_search_products(text,boolean,int,int) from public, anon;
grant execute on function public.admin_search_products(text,boolean,int,int) to authenticated;
revoke all on function app.product_batch_json(public.product_import_batches) from public, anon, authenticated;
revoke all on function app.product_code_acceptable(text) from public, anon, authenticated;
-- write_r8_application 沿用既有授權（create or replace 不改變權限）
