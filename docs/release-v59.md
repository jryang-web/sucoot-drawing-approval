# V5.9 產品智慧搜尋與 Excel 主檔同步｜發布與回復方案

> 狀態：**僅完成隔離環境開發與測試**。未修改正式 Supabase、未執行正式 migration、未匯入正式產品資料、未合併 main、未部署 GitHub Pages。
> 以下步驟須經使用者明確核准後才可執行。

## 1. 變更範圍

| 類別 | 項目 |
|---|---|
| 資料庫 | `supabase/migrations/20261126000030_product_master.sql`（新增 4 張表、5 個 RPC、2 個內部函式；`write_r8_application` 產品編碼檢查放寬為「V5.8 規則 **或** 存在於產品主檔」） |
| 擴充套件 | `pg_trgm`（安裝於 `extensions` schema，Supabase 內建可用） |
| 前端 | 新增申請頁產品搜尋（`public/r8-form.html`、`src/pages/R8Form.tsx`）；系統管理「產品主檔管理」（`src/pages/admin/ProductMaster.tsx`、`src/lib/xlsx.ts`） |
| 相依套件 | `fflate@0.8.2`（MIT，解壓 .xlsx；只在管理員匯入頁載入） |
| 不變 | 雙層審核流程、案件狀態、角色權限、Auth、既有 RLS、LINE Mock、SUCOOT LOGO、`admin-accounts` Edge Function |

## 2. 正式發布步驟（需核准）

1. **發布前核對**
   - 確認正式專案為 `qifjiaxskortyennnpsh`，`supabase_migrations.schema_migrations` 最新版本為 `20261120000029`。
   - 確認 `pg_trgm` 可用：`select * from pg_available_extensions where name = 'pg_trgm'`。
   - 確認 `public.write_r8_application` 現行定義與 migration 14 相同（避免覆蓋未知的線上修正）。
2. **套用 migration 030**（單一交易；失敗即全部回滾）。
3. **權限核對**（同一連線）：
   - `anon`、`authenticated` 對 `products`、`product_master_state`、`product_import_batches`、`product_import_rows` 無任何資料表權限。
   - `authenticated` 可執行 `search_products`、`admin_product_*`；`anon` 不可。
   - `write_r8_application` 的 EXECUTE 權限與發布前相同。
4. **部署前端**：合併 PR 至 `main`，GitHub Actions 自動建置與部署 Pages。
5. **匯入正式產品主檔**：系統管理員登入 →「系統管理 → 產品主檔管理」→ 上傳 `產品編碼對照表(2).xlsx` → 核對預覽（應為新增 7,004、錯誤 0）→ 確認同步。
6. **上線驗證**：一般員工帳號搜尋 `F26509`、`槽鋼 2000`、`55×2`；新增申請帶入產品並儲存草稿（不送出）後刪除／取消。

> 前端與資料庫的相容性：migration 030 先上線、前端後上線時，V5.8 前端完全不受影響（新增的 RPC 未被呼叫；`write_r8_application` 只放寬）。前端先上線、migration 未上線時，搜尋會顯示「搜尋失敗」，手動輸入仍可用。建議順序：**先 migration、後前端**。

## 3. 回復方案

| 情境 | 回復方式 | 影響 |
|---|---|---|
| 前端問題 | GitHub 回復（revert）合併提交，Actions 重新部署 V5.8 前端 | 搜尋與匯入頁消失；資料庫新物件保留但不被呼叫，不影響 V5.8 |
| 產品資料匯入錯誤 | 重新上傳正確的完整 Excel 並同步（停用者會重新啟用、資料會被覆蓋為新檔內容） | 不需改資料庫結構 |
| 需移除資料庫變更 | 執行下方回復 SQL（單一交易） | 產品主檔與匯入紀錄刪除；案件資料不受影響（案件只保存文字，不參照產品表） |

回復 SQL（僅於核准後在正式環境執行）：

```sql
begin;
-- 1) 還原 V5.8 的產品編碼檢查（migration 14 原定義）
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
      coalesce(trim(x->>'code'),'') !~ '^[A-Za-z0-9_./-]{1,30}$' or nullif(trim(x->>'name'),'') is null)
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
-- 2) 移除 V5.9 物件
drop function if exists public.search_products(text,int,int);
drop function if exists public.admin_product_import_preview(text,text,jsonb,jsonb);
drop function if exists public.admin_product_import_commit(uuid,boolean);
drop function if exists public.admin_product_master_summary();
drop function if exists public.admin_search_products(text,boolean,int,int);
drop function if exists app.product_code_acceptable(text);
drop function if exists app.product_batch_json(public.product_import_batches);
drop table if exists public.product_import_rows, public.product_import_batches, public.product_master_state, public.products;
-- pg_trgm 保留（無害；若確認無其他用途可另行移除）
commit;
```

注意：若回復前已有員工以含 `×`、`"` 的主檔編碼送出案件，這些案件**已保存的資料不受影響**；但退回後再次編輯時，該編碼會被 V5.8 規則擋下，需改用手動合規編碼。

## 4. 已知限制與後續

- 搜尋採關鍵字包含比對（`ILIKE` + `pg_trgm` 索引），不做錯字容錯或同義詞。
- 匯入只讀 Excel 第一個工作表、第一列欄名須為「產品代碼、品名、規格」。
- 預覽 60 分鐘內有效；只能由預覽的同一位管理員確認。
- 匯入暫存資料（`product_import_rows`）保留於資料庫供稽核，可定期清理已同步超過一定期間的批次。
