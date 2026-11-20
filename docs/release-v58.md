# V5.8 發布準備

## GitHub Pages 與 Supabase

- 本機使用 `npm run dev`，或 `npm run build` 建置隔離測試版。瀏覽器限 loopback，同源 API 由本機代理轉送。
- Pages 工作流程與手動發布腳本均以 `npm run build -- --mode pages` 建置。單獨執行此建置指令可供審核。GitHub Actions 的 Repository Variables 須設定 `VITE_SUPABASE_URL=https://qifjiaxskortyennnpsh.supabase.co` 與 `VITE_SUPABASE_PUBLISHABLE_KEY`。後者從該專案 API Keys 取得啟用中的 publishable key，亦支援此專案的 legacy anon JWT。本機建置 Pages 時可用同名環境變數。前端設定會公開，私鑰與 service role 僅能留在後端。
- Auth、REST、Edge Function 共用同一個 Supabase client，分別連到指定專案的 `/auth/v1`、`/rest/v1`、`/functions/v1/admin-accounts`。登入使用員工編號及既有內部信箱網域。發布前核對 Auth Site URL 與實際使用的 redirect allowlist 指向 Pages 專案網址，確認公開註冊停用。
- 正式切換時須核對並發布同版本的 admin-accounts，確認平台注入 SUPABASE_URL、SUPABASE_ANON_KEY、SUPABASE_SERVICE_ROLE_KEY，並驗證函式與入口接受實際 Auth 工作階段 JWT、CORS 允許 Pages 呼叫。管理員授權由後端驗證。LINE 維持 Mock。
- main 有推送即觸發 Pages 工作流程，手動 dispatch 或發布腳本也會發布。發布窗口前僅執行建置。

## V5.7 基線核對

以 GitHub feature/v5.8 的 f7a810f 為準，逐一比對雲端 schema_migrations.statements 與 SQL 原檔。八筆皆有原始文字差異；排除註解、排版後，保留引號字串的 SQL 詞元及順序逐筆相符。

| GitHub 版本 | 雲端版本 | 名稱 |
|---|---|---|
|20261116000001|20261116062212|core_org|
|20261116000002|20261116062358|admin_rpc|
|20261116000003|20261116062619|drawing_requests|
|20261116000004|20261116062644|bootstrap_admin|
|20261116000005|20261116062727|hardening|
|20261116000006|20261116063817|select_grants|
|20261117000007|20261117080008|employee_directory|
|20261117000008|20261117080656|directory_invoker_view|

雲端 app schema 與其 24 個函式、public 的 31 個函式、16 張表、2 個 view、3 個 sequence、33 個索引皆由 postgres 持有。public schema 由 pg_database_owner 持有。supabase_migrations schema 與 schema_migrations 表由 postgres 持有。auth schema 由 supabase_admin 持有，auth.users、auth.sessions 由 supabase_auth_admin 持有。

## 正式升級計畫（業務測試資料可捨棄）

選用現有 V5.7 結構原地升級。09～22 已依賴既有物件；清空案件再重建結構會增加外鍵、函式擁有者及權限重設工作。現有兩件測試案可留在原處，本輪清理範圍為零。若日後確有資料衝突，先列出受影響的 SUCOOT 測試案件與相依業務列，再限定清理範圍。

1. 保留既有 Auth 使用者、員工編號、部門、角色、主管管轄及安全稽核。採用已核准跳過完整備份與預演的決策。升級前後比對帳號與組織關聯、物件擁有者及有效權限。
2. 維持業務停寫與 admin-accounts 維護模式。使用受控正式 postgres 連線，確認目標專案及上表八筆基線；核對 09～22 版本、內容及順序。前八筆維持正式紀錄。
3. 每筆在同一交易執行原 migration、撤銷新開放的寫入權、檢查實際有效權限並登錄對應版本。檢查涵蓋 anon、authenticated、PUBLIC 與繼承權限，以及可寫表、可更新 view、寫入 RPC。任何不符使交易失敗。提交後用獨立連線複核停寫及版本；通過才執行下一筆。
4. 遇到失敗立即停止，記錄最後成功版本並維持停寫。保留已提交交易，不重置專案或 schema。本輪截止於資料庫核對，保留 LINE Mock 與帳號函式維護模式；網站發布及解除停寫另行處理。

## v58-fix 增量升級順序（接續 22）

1. `20261120000023_cancel_request_states.sql`
2. `20261120000024_principal_creates_delegation.sql`
3. `20261120000025_review_already_handled.sql`
