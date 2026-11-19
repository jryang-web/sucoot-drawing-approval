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

## 經核准後的升級與回復

1. 在獨立發布工作目錄組裝 migration 集合。複製前八份 SQL 並僅將副本的檔名前綴改為上表雲端版本，接續放入原樣的 09～22。保留 Git 歷史與正式資料庫原有八筆紀錄。核對 SHA 與檔案雜湊，用正式基線的隔離還原副本預演，確認 CLI 計畫只有後十四筆且順序一致。
2. 以 postgres 為建立應用物件的有效角色，核對 public/app 建立權限及 17 號 migration 所需的 auth.users trigger、密碼更新與工作階段撤銷權限。保留 Auth 物件擁有者。從 authenticated 呼叫 RPC 驗證權限鏈。若託管環境的權限不足，暫停並取得平台支援。
3. 核准維護窗口後停寫；保存可還原的資料庫備份（含 Auth、資料、政策、函式、ACL 與 migration 紀錄）、角色及版本設定，保存 V5.7 Pages 產物與 Edge Function 版本。確認還原責任人及備份可用性。
4. 再做唯讀基線核對及 dry-run。只接受 09～22，任何缺號、舊版重跑或 drift 都須停止。由支援交易的 migration 工具逐筆執行及登錄，核對成功版本、物件擁有者與權限。先驗證後端及 Edge Function，再切換 Pages，以管理員及一般使用者核對登入、REST 與帳號管理。
5. 任一步失敗就保持停寫、停止後續切換，記錄最後成功版本。已提交的前序 migration 會保留。依核准方案回到一致備份及配套 V5.7 前端與函式版本，驗證登入、舊案及權限後才恢復寫入。
