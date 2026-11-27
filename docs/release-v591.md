# V5.9.1 PWA 角標與背景推播｜發布與回復方案

> **狀態：開發分支 `feature/v5.9.1-pwa-push-badge`，僅完成隔離環境測試。**
> 未修改正式 Supabase、未執行正式 migration、未部署 Edge Function、未設定 Secrets、未合併 `main`、未部署 Pages、未對任何正式員工發送推播。
> 以下每一步都需要使用者另行明確授權。

## 1. 變更範圍

| 類別 | 內容 |
|---|---|
| 資料庫 | `supabase/migrations/20261127000032_badge_and_push.sql`（僅新增；不修改任何既有業務 RPC、RLS、權限） |
| Edge Function | `supabase/functions/push-dispatch/`（`index.ts`、`dispatch.ts`、`webpush.ts`） |
| 前端 | 角標同步、通知與角標卡片、啟用通知、登出清除、Service Worker 推播與通知點擊 |
| 圖示 | **不變**：V5.8（PR #7）已使用公司正式 LOGO，尺寸齊全，未重複修改 |

## 2. Secrets 準備（公司授權系統維護人員自行操作）

> **Claude 與開發人員不產生、不經手正式金鑰。** 私鑰與排程密鑰不得出現在聊天、GitHub、SQL migration、測試日誌、截圖或終端機指令列。

| 名稱 | 機密 | 存放位置 | 說明 |
|---|---|---|---|
| `VAPID_PUBLIC_KEY` | 否（公開值） | Edge Function Secrets | P-256 公鑰（base64url，87 字元）。前端以 `GET push-dispatch` 取得 |
| `VAPID_PRIVATE_KEY` | **是** | Edge Function Secrets | 對應私鑰（base64url，43 字元） |
| `VAPID_SUBJECT` | 否 | Edge Function Secrets | `mailto:<公司正式 IT 維護信箱>`（建議）或 `https://www.sucoot.com/`（見 2.1） |
| `PUSH_CRON_SECRET` | **是** | Edge Function Secrets **與** Vault（同一值） | 排程呼叫用，256 位元隨機值 |
| `SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`SUPABASE_ANON_KEY` | — | 平台自動注入 | 不需設定 |

### 2.1 VAPID_SUBJECT 建議

- **標準**：RFC 8292 規定 `sub` 應為 `mailto:` 或 `https:` URI，讓推播服務（Apple、Google、Mozilla）在發送異常時能聯絡應用程式擁有者；Apple 推播服務會拒絕格式不符的 `sub`。
- **程式支援**：`push-dispatch` 兩種格式皆接受（`vapidSubjectValid`）；格式錯誤時函式回 `VAPID_SUBJECT_INVALID`，**不取出佇列**，避免整批失敗。`http:`、純信箱（缺 `mailto:`）、本機網址一律拒絕。
- **建議優先**：`mailto:<公司正式 IT 維護信箱>`——推播服務可直接聯絡到負責人。
- **替代**：`https://www.sucoot.com/`——符合標準，但僅代表公司網站識別，**不等於有專屬 IT 聯絡信箱**；推播服務若需聯絡，可能無法直接找到維護人員。
- **正式採用值須由公司維護人員確認。**

### 2.2 產生與驗證金鑰（在維護人員自己的電腦，需 Node.js 18 以上）

```bash
# 1. 產生：檔案寫在專案以外的私人資料夾（權限 700／600）；畫面只顯示公鑰
node scripts/vapid-keys.mjs generate ~/sucoot-push-keys
# 2. 驗證：格式、公私鑰配對（以私鑰簽章、公鑰驗證）、檔案權限、VAPID_SUBJECT 格式；不顯示私鑰
node scripts/vapid-keys.mjs verify ~/sucoot-push-keys "mailto:<公司正式 IT 維護信箱>"
```

- 產生三個檔案：`vapid_public_key.txt`、`vapid_private_key.txt`、`push_cron_secret.txt`（排程密鑰為 32 bytes 隨機值）。
- 工具拒絕覆寫既有檔案、拒絕寫入專案資料夾；不連網；只用 Node.js 內建 crypto。
- 密鑰只存在檔案中、不出現在指令列，因此不會進入終端機歷史。驗證結果只顯示公鑰與私鑰指紋（SHA-256 前 12 碼），可用來核對，但無法還原私鑰。
- 不建議 `npx web-push generate-vapid-keys`：它會把私鑰直接顯示在畫面上（留在終端機捲動紀錄）。

### 2.3 填入 Edge Function Secrets（Dashboard）

1. 登入 Supabase Dashboard → 專案 `sucoot-drawing-dev`（`qifjiaxskortyennnpsh`）→ **Edge Functions → Secrets**。
2. 依序新增四筆（Key 與 Value）：`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT`、`PUSH_CRON_SECRET`。Value 以文字編輯器開啟對應檔案後複製貼上（`VAPID_SUBJECT` 直接輸入確認後的值）；注意不要多貼空白或換行。
3. 儲存。Secrets 立即生效，不需重新部署。
4. 核對：Dashboard 的 Secrets 清單只顯示雜湊／名稱即可；**不要**以任何方式把值顯示或匯出。

### 2.4 `PUSH_CRON_SECRET` 存入 Vault（僅在啟用排程時）

1. Dashboard → **Vault**（Integrations 或 Database 選單下，依 Dashboard 版本）→ **Add new secret**。
2. Name：`sucoot_push_cron_secret`；Secret：貼上與 Edge Function 相同的 `PUSH_CRON_SECRET`。
3. **不要**在 SQL Editor 以 `vault.create_secret('<值>', …)` 建立：SQL Editor 會保存查詢紀錄與片段，密鑰會以明文留存。

### 2.5 完成後清理

- 填入並確認函式正常（第 3 節步驟 4）後，刪除 `~/sucoot-push-keys` 三個檔案（或移至公司核准的密碼保管系統，**私鑰備份須與一般檔案分開**）。
- 不要把檔案放入雲端同步資料夾、Email、即時通訊或 GitHub。
- **更換金鑰**：重新產生並更新 Secrets 後，所有裝置需重新按「啟用通知」（前端偵測公鑰不同時會重新訂閱）。

## 3. 正式發布步驟（依序；每步需授權）

1. **發布前核對（唯讀）**
   - 正式 migration 紀錄 30 筆，最新為 `v59_product_master_safeupdate`。
   - 確認 `app.l1_authority`、`app.has_role`、`app.current_employee_id`、`app.personal_security_notices` 與 repo 定義一致。
2. **套用 migration 032**（單一交易）。
3. **權限核對**（同一連線）：
   - `anon`、`authenticated` 對 `app.push_*` 四張表無任何權限。
   - `my_badge_summary`、`push_register`、`push_unregister`、`push_status`、`admin_push_summary` 僅 `authenticated` 可執行；`anon` 不可。
   - `svc_push_claim`、`svc_push_report` 僅 `service_role` 可執行。
   - 執行 `tests/local/v59_safeupdate_check.sql` 的查詢：0 筆。
4. **設定 Secrets**（第 2 節），再部署 Edge Function `push-dispatch`，**關閉平台 JWT 驗證**（CLI：`supabase functions deploy push-dispatch --no-verify-jwt`；或 Dashboard 函式設定關閉「Enforce JWT verification」）。
   - 理由：排程呼叫沒有使用者 JWT；函式自行驗證呼叫者（員工 JWT 經 `me()` 確認有效員工，或比對排程密鑰；排程密鑰未設定時一律拒絕）。GET 只回傳公開的 VAPID 公鑰。這也是 Supabase 文件對自行驗證之函式的建議做法。
   - 部署後由已登入員工在 App 開啟「通知與角標」：若顯示「推播服務尚未設定」，代表 Secrets 缺漏或金鑰不配對（函式只回傳錯誤代碼 `PUSH_NOT_CONFIGURED`／`VAPID_KEY_MISMATCH`／`VAPID_SUBJECT_INVALID`，可在函式日誌查看）。
5. **（建議）排程重試**（migration 033＋下列 SQL；**全程不經手任何密鑰**）：

   ```sql
   create extension if not exists pg_net;
   create extension if not exists pg_cron;
   -- 排程密鑰在資料庫內隨機產生、直接存入 Vault，不輸出
   select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'sucoot_push_cron_secret',
                              'V5.9.1 推播排程密鑰（資料庫內產生）') is not null as created;
   select cron.schedule('sucoot-push-dispatch', '* * * * *', $job$
     select net.http_post(
       url := 'https://qifjiaxskortyennnpsh.supabase.co/functions/v1/push-dispatch',
       headers := jsonb_build_object('Content-Type', 'application/json',
         'x-push-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sucoot_push_cron_secret')),
       body := '{}'::jsonb)
     where exists (select 1 from app.push_outbox where status in ('PENDING','SENDING') and next_attempt_at <= now());
   $job$);
   ```

   - `push-dispatch` 以 `svc_push_cron_ok`（僅 service_role 可執行）在資料庫內比對 Vault 的值；Edge Function Secret `PUSH_CRON_SECRET` 仍可用於手動呼叫。
   - 只有佇列中有到期項目時才呼叫；重試流程：5xx／逾時／連線失敗 → 1、4、16、64 分鐘後重試，共 5 次後 FAILED；404／410 → 停用該裝置訂閱。
   - 驗證：`select * from cron.job_run_details order by start_time desc limit 5;`、`select status_code from net._http_response order by created desc limit 5;`（200＝已處理；401＝密鑰不一致）。
   - 移除：`select cron.unschedule('sucoot-push-dispatch');`，並於 Vault 刪除 `sucoot_push_cron_secret`。

6. **合併前端**（PR → `main` → GitHub Pages 自動部署）。
7. **實機驗收**（第 5 節）。

> 若只部署前端與 migration、尚未設定推播（步驟 4 未完成）：角標與 App 內計數正常；「啟用通知」會顯示「推播服務尚未設定」，不影響其他功能。

## 4. 回復方案

**順序：先回復前端，再回復資料庫**（新前端呼叫 `my_badge_summary`；資料庫先移除時，只有「通知與角標」卡片顯示錯誤，其他功能不受影響）。

1. 前端：revert 合併 commit 後推送 `main`（Pages 重新部署）。已開啟的 PWA 需按「更新」或重新開啟。
2. 排程（若已建立）：`select cron.unschedule('sucoot-push-dispatch');`
3. Edge Function：於 Dashboard 刪除 `push-dispatch`，並刪除 `VAPID_*`、`PUSH_CRON_SECRET` Secrets 與 Vault 中的 `sucoot_push_cron_secret`。
4. 資料庫（單一交易；**已在隔離資料庫實測**：V5.9.1 物件全數移除，正式送件仍正常）：

   ```sql
   begin;
   drop trigger if exists enqueue_push on public.drawing_requests;
   drop trigger if exists revoke_push_on_disable on public.employees;
   drop trigger if exists revoke_push_on_credential_reset on public.employees;
   drop function if exists public.svc_push_claim(int), public.svc_push_report(bigint[], jsonb), public.admin_push_summary(int),
     public.push_register(text, text, text, text), public.push_unregister(text), public.push_status(text), public.my_badge_summary();
   drop function if exists app.enqueue_push_for_request(), app.revoke_employee_push(), app.badge_counts(uuid),
     app.pending_kind(uuid, public.drawing_requests), app.push_endpoint_allowed(text);
   drop table if exists app.push_deliveries, app.push_outbox, app.push_enqueue_errors, app.push_subscriptions;
   commit;
   ```

   回復會刪除裝置訂閱與推播紀錄（不影響任何案件、審核、稽核資料）。手機上已顯示的角標，在使用者開啟舊版 App 後不會自動清除；可請使用者重新開啟或移除通知權限。

## 5. 實機驗收步驟（隔離環境無法代替）

### iPhone（T25）
1. iOS 16.4 以上；以 Safari 開啟正式網站 →「分享」→「加入主畫面」。
2. 從主畫面開啟 SUCOOT 並登入 → 工作首頁「通知與角標」→「啟用通知」→ 允許。
3. 「設定 > 通知 > SUCOOT」確認「允許通知」與「標記」皆開啟。
4. 關閉 App（滑掉）。由另一位員工送出一件此人可審核的案件。
5. 確認：鎖定畫面／通知中心出現「SUCOOT 圖面申請」通知；主畫面圖示角標數字＝App 內「角標合計」。
6. 點通知 → 開啟案件明細；完成審核後回主畫面，角標下降。
7. 登出 → 角標清除；再由他人送件 → 此裝置不再收到通知。

### Android（T26）
1. Chrome 開啟正式網站 →「安裝應用程式」。
2. 啟用通知（同上第 2 步）。
3. 關閉 App，由他人送件 → 確認收到通知；圖示上的提示依手機品牌（數字或圓點，或僅通知）。
4. 點通知 → 開啟案件明細。

驗收時請記錄：事件時間、通知出現時間、角標數字、App 內數字；管理員可在資料庫以 `admin_push_summary()` 查看推播服務是否接受（**接受 ≠ 手機已收到**）。
