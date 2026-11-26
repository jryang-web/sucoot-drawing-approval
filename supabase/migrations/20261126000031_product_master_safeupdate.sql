-- SUCOOT V5.9 修正：正式 Supabase 對 PostgREST 連線啟用 safeupdate（UPDATE／DELETE 必須有 WHERE）。
-- migration 030 的 admin_product_import_commit 更新單列主檔版本時未寫 WHERE，正式環境確認同步時被拒絕
-- （交易已整批回滾，未寫入任何產品）。僅補上 `where id`（單列表的主鍵恆為 true），其餘邏輯、權限不變。

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

  update public.product_master_state set version = version + 1, updated_at = now() where id;
  update public.product_import_batches set status = 'COMMITTED', committed_by = me, committed_at = now(),
         high_risk_confirmed = b.high_risk
   where id = b.id returning * into b;
  perform app.audit(me, 'PRODUCT_IMPORT_COMMIT', 'product_import', b.id::text, jsonb_build_object('version', st.version),
    jsonb_build_object('version', st.version + 1, 'file', b.file_name, 'total', b.total_rows, 'added', n_add, 'updated', n_upd,
                       'unchanged', b.unchanged, 'reactivated', n_react, 'deactivated', n_deact, 'high_risk_confirmed', b.high_risk), null);
  return app.product_batch_json(b);
end $$;
