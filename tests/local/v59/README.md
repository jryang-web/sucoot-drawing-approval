# V5.9 隔離測試環境（不需 Docker）

只在本機建立的 PostgreSQL 16 執行，**不連線、不修改正式 Supabase**。

| 檔案 | 用途 |
|---|---|
| `shim.sql` | 模擬 Supabase 平台物件：`anon`／`authenticated`／`service_role` 角色、`auth.users`／`auth.sessions`、`auth.uid()`／`auth.jwt()`、`extensions.pgcrypto` |
| `fixture.sql` | 合成測試組織：製造部／工程部／圖管部／管理部，TEST001–TEST008 與 admin |
| `setup.sh` | 重建資料庫：initdb → shim → 依序套用 `supabase/migrations/*.sql` → fixture（資料在 `/var/lib/postgresql/sucoot-v59`，只開 Unix socket） |
| `bridge/bridge.mjs` | UI 測試用 API 橋接（127.0.0.1:54329）：Auth 測試替身＋RPC／唯讀查詢以 `authenticated` 角色與 JWT claims 執行 |
| `regress.sh` | 差異式回歸：對指定程式版本重建資料庫並執行 V5.8 既有測試（fix1–6、p4_recovery、personal_security_notices、business_operations.py） |
| `e2e.cjs`、`preview.cjs` | Playwright 端對端與手機版面檢查（管理員匯入、員工搜尋送件） |
| `webkit-safari.cjs` | Safari 相容性：Playwright WebKit＋iPhone 13 設定，測產品搜尋、自動帶入、多筆產品、手動輸入（需另行下載 WebKit：`PLAYWRIGHT_BROWSERS_PATH=<資料夾> playwright install webkit`） |
| `tools/` | Excel 原始 XML 稽核、資料庫與 Excel 逐筆比對、測試用 Excel 變體產生 |

## 使用方式

```bash
export PGHOST=/var/lib/postgresql/sucoot-v59/run PGPORT=54330 PGUSER=postgres PGDATABASE=postgres
(cd tests/local/v59/bridge && npm install)
bash tests/local/v59/regress.sh "$PWD" v5.9            # 重建資料庫＋V5.8 回歸＋啟動橋接
psql -v ON_ERROR_STOP=1 -f tests/local/v59_product_master.sql   # V5.9 後端 62 項（交易內執行並回滾）
bash tests/local/v59_concurrency.sh                      # 多管理員並發匯入（會寫入隔離資料庫）
npm run build && npx vite preview --host 127.0.0.1 --port 4173   # 本機前端（代理到 54329）
node tests/local/v59/e2e.cjs <輸出資料夾> <產品 Excel 路徑>
```

測試帳號的本機密碼由 `regress.sh` 寫入隔離資料庫，僅供本機使用。
