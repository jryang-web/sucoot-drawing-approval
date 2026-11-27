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

## 2. 正式部署前需要準備（不得寫入 GitHub 或聊天）

| 名稱 | 類型 | 說明 |
|---|---|---|
| `VAPID_PUBLIC_KEY` | Edge Function Secret（公開值） | P-256 公鑰（base64url，65 bytes）。前端透過 `GET push-dispatch` 取得 |
| `VAPID_PRIVATE_KEY` | Edge Function Secret（**機密**） | 對應私鑰（base64url，32 bytes）。**只放 Supabase Secrets** |
| `VAPID_SUBJECT` | Edge Function Secret | 聯絡資訊，例如 `mailto:<公司 IT 信箱>` 或正式網站網址 |
| `PUSH_CRON_SECRET` | Edge Function Secret＋Vault（**機密**） | 排程重試呼叫用的隨機字串（建議 32 bytes 以上） |
| `SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`SUPABASE_ANON_KEY` | 平台自動注入 | 不需手動設定，不得寫入程式 |

VAPID 金鑰由公司授權維護人員於自己的電腦產生（例如 `npx web-push generate-vapid-keys`），直接貼入 Supabase Dashboard → Edge Functions → Secrets。**金鑰一旦更換，所有裝置需重新啟用通知**（前端會偵測公鑰不同並在下次啟用時重新訂閱）。

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
4. **設定 Secrets**（第 2 節），再部署 Edge Function `push-dispatch`。
   - 建議 `verify_jwt = false`：函式自行驗證（員工 JWT 經 `me()` 確認、或排程密鑰），GET 只回傳公開的 VAPID 公鑰。若維持預設 `verify_jwt = true`，排程呼叫需另帶有效 JWT。
5. **（建議）排程重試**：啟用 `pg_net`、`pg_cron`，將 `PUSH_CRON_SECRET` 存入 Vault，每分鐘在佇列有到期項目時呼叫一次：

   ```sql
   create extension if not exists pg_net;
   create extension if not exists pg_cron;
   -- 秘密值由維護人員在 SQL Editor 輸入，不寫入 repo
   select vault.create_secret('<PUSH_CRON_SECRET>', 'sucoot_push_cron_secret');
   select cron.schedule('sucoot-push-dispatch', '* * * * *', $job$
     select net.http_post(
       url := 'https://qifjiaxskortyennnpsh.supabase.co/functions/v1/push-dispatch',
       headers := jsonb_build_object('Content-Type', 'application/json',
         'x-push-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sucoot_push_cron_secret')),
       body := '{}'::jsonb)
     where exists (select 1 from app.push_outbox where status in ('PENDING','SENDING') and next_attempt_at <= now());
   $job$);
   ```

   未設定排程時，推播仍會在員工完成案件操作後由前端觸發發送；但暫時失敗的重試要等到下一次有人操作。
6. **合併前端**（PR → `main` → GitHub Pages 自動部署）。
7. **實機驗收**（第 5 節）。

> 若只部署前端與 migration、尚未設定推播（步驟 4 未完成）：角標與 App 內計數正常；「啟用通知」會顯示「推播服務尚未設定」，不影響其他功能。

## 4. 回復方案

**順序：先回復前端，再回復資料庫**（新前端呼叫 `my_badge_summary`；資料庫先移除時，只有「通知與角標」卡片顯示錯誤，其他功能不受影響）。

1. 前端：revert 合併 commit 後推送 `main`（Pages 重新部署）。已開啟的 PWA 需按「更新」或重新開啟。
2. 排程（若已建立）：`select cron.unschedule('sucoot-push-dispatch');`
3. Edge Function：於 Dashboard 刪除 `push-dispatch`，並刪除 `VAPID_*`、`PUSH_CRON_SECRET`。
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
