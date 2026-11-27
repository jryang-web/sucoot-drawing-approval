# V5.9.1 PWA 角標、未讀計數與背景推播｜開發與測試報告

- 日期：2026-11-27
- 分支：`feature/v5.9.1-pwa-push-badge`（基準 `main` @ `0779280`，即 V5.9＋PR #9）
- 環境：**隔離本機 PostgreSQL 16**（Supabase shim＋全部 32 個 migration）、本機 API 橋接、本機假推播服務；未連線正式 Supabase，未對任何真實裝置發送推播
- 發布與回復：`docs/release-v591.md`

## 1. 調查結論

| 項目 | 結論 |
|---|---|
| 必讀文件 | `AGENTS.md`、`README.md` 已讀；`claude/SUCOOT-V5.9-上線紀錄.md`、`claude/SUCOOT-V5.8.md` **不存在**（repo 無 `claude/` 目錄） |
| PWA 圖示 | V5.8（PR #7）已改為公司正式 LOGO：favicon 32、Apple 180、192、512、maskable 512（標誌在安全區內），manifest、HTML、Service Worker 預先快取皆正確引用 → **不修改** |
| 未讀通知來源 | 沿用 `app.personal_security_notices`（`read_at`，最近 30 天，與通知中心顯示範圍相同）。不計入管理員的 `exception_notices`：其對應的整案異常案件已列入待辦，計入會重複 |
| 待辦來源 | 首頁分類是前端篩選；實際授權在後端 RPC。角標以後端判斷為準，逐條對應 `review_level1`（部門管轄＋有效代理）、`review_level2`（排除申請人與本輪第一層核准者）、`claim_issue`／`record_issue`（認領歸屬）、`confirm_receipt`、`submit_request` |
| 首頁小修正 | 「目前待辦」同一案件只列一次；第二層待審排除自己送出的案件（後端原本即拒絕）。其他首頁邏輯不變 |
| 新資料表必要性 | 訂閱、推播佇列、發送紀錄沒有既有資料表可用；新增於 `app` schema（PostgREST 不公開），員工只能經 RPC 操作自己的訂閱 |

## 2. 功能與架構

| 項目 | 實作 |
|---|---|
| 待辦判斷（單一來源） | `app.pending_kind(員工, 案件)`：回傳 `RETURNED／L1／L2／ISSUE／ABNORMAL／RECEIPT` 或 null。案件同時只有一個狀態，因此多角色不會重複計數 |
| 角標 API | `public.my_badge_summary()`：無參數，身分取自登入工作階段（`app.require_employee`：未登入、停用、工作階段失效、需先改密碼皆拒絕）。回傳 `unread_notices`、`pending_cases`、`total`、`by_kind`、`as_of` |
| 前景同步 | `src/lib/badge.ts`：登入／開啟、返回前景、恢復連線、完成案件操作、已讀、切換工作首頁、收到推播；同時間只有一個查詢，1.5 秒內的重複觸發合併為一次（時間到補查，不遺漏）；換帳號丟棄舊查詢結果；離線時標示資料時間 |
| Badging API | 先檢查支援；`setAppBadge(n)`／`clearAppBadge()` 失敗只改變提示，不中斷操作；登出清除 |
| 裝置訂閱 | `push_register`（只接受 FCM、Apple、Mozilla、Windows 推播服務的 HTTPS 網址；金鑰格式檢查；綁定登入工作階段；同裝置換帳號改歸新帳號；每人最多 10 台）、`push_unregister`（只能停用自己的）、`push_status` |
| 自動停用訂閱 | 帳號停用、管理員重設密碼／重新啟用（須改密碼）時全部停用；登出時前端停用；工作階段失效後不再發送到該裝置 |
| 推播佇列 | `drawing_requests` AFTER UPDATE 觸發器：異動後找出「現在」有待辦的員工排入佇列（排除操作者）；以「案件＋狀態＋輪次＋負責人＋認領＋員工」簽章去重；**整段以例外處理包住，失敗只記錄於 `app.push_enqueue_errors`，不回滾業務交易** |
| 發送端 | Edge Function `push-dispatch`：`svc_push_claim`（`for update skip locked`、送出前重新確認收件資格、依員工合併、附即時角標）→ WebCrypto 實作 RFC 8291／8292 加密與 VAPID → `svc_push_report`（2xx＝推播服務接受；404／410 停用訂閱；其他失敗以 1／4／16／64 分鐘退避，最多 5 次） |
| Service Worker | `push`：以推播中的數字設定角標、顯示通知（內容無法解析時顯示一般通知）、通知已開啟的 App 重新同步；`notificationclick`：只接受 `#/my`、`#/r/<uuid>` 路由，已開啟時切換頁面（不重新載入），否則開新視窗；未登入時由登入頁接手，登入後由後端檢查案件權限 |
| 管理員追查 | 「系統管理 → 推播發送紀錄」：狀態、嘗試次數、失敗原因；不顯示 endpoint、金鑰、通知內容 |
| 推播內容 | 只有角標數字、標題、「有 N 件『類別』案件等待處理」、點擊路由；不含案件編號、申請人、產品資料、Token |

## 3. 測試結果

| 測試套件 | 方式 | 結果 |
|---|---|---|
| V5.9.1 後端 | `tests/local/v591_badge_push.sql`（交易內執行並回滾） | ✅ **82/82**（第二輪新增 12 項，見第 6 節） |
| V5.9.1 發送端 | `tests/local/v591/push-dispatch.test.mts`（獨立實作 `http_ece` 解密、Node crypto 驗證 VAPID） | ✅ **21/21**（第二輪新增 6 項） |
| V5.9.1 瀏覽器 | `tests/local/v591/ui.cjs`（Chromium 桌面、Pixel 7 模擬、WebKit iPhone 13 模擬） | ✅ **40/40** |
| V5.8 回歸 | `regress.sh`（fix1–6、p4_recovery、personal_security_notices、business_operations.py） | ✅ **9/9** |
| V5.9 產品主檔後端 | `v59_product_master.sql` | ✅ **62/62** |
| V5.9 端對端／手機版面／WebKit 產品搜尋 | `e2e.cjs`、`preview.cjs`、`webkit-safari.cjs` | ✅ **16/16、19/19、25/25** |
| safeupdate 靜態掃描 | `v59_safeupdate_check.sql` | ✅ 0 筆 |
| 回復 SQL | 隔離資料庫交易內執行 | ✅ V5.9.1 物件剩 0；回復後正式送件成功 |
| 型別檢查、ESLint、建置；測試與 Edge Function 共用模組型別檢查 | `npm run typecheck`、`lint`、`build`；`tsc -p tests/local/v591` | ✅ |

### 3.1 指定測試項目

| 編號 | 項目 | 結果 | 證據 |
|---|---|---|---|
| T01 | 未讀 2＋待辦 3＝角標 5 | ✅ 通過 | 後端：退回 2＋待簽收 1、未讀 2（30 天前與已讀不計） |
| T02 | 同一案件多角色不重複 | ✅ 通過 | 後端：部門主管＋圖管主管＋圖管人員＋管理員，角標＝首頁各分類去重數；全部員工逐一比對 |
| T03 | 完成待辦後下降 | ✅ 通過 | 後端：核准、簽收後下降；瀏覽器：返回前景後角標 −1 |
| T04 | 已讀後下降 | ✅ 通過 | 後端 5→4；瀏覽器按「標為已讀」後角標 −1 |
| T05 | 無通知與待辦時清除 | ✅ 通過 | 後端 total=0；前端 0 時呼叫 `clearAppBadge` |
| T06 | 不同員工隔離 | ✅ 通過 | 後端；函式無員工參數 |
| T07 | 未登入不可查詢 | ✅ 通過 | anon：permission denied；無身分 authenticated：拒絕 |
| T08 | 停用員工不可查詢或訂閱 | ✅ 通過 | ACCOUNT_INACTIVE；重設密碼後 PASSWORD_CHANGE_REQUIRED；訂閱自動停用 |
| T09 | 部門主管只收授權部門 | ✅ 通過 | 製造部案件只排入製造部主管 |
| T10 | 圖管主管不收不能核准的案件 | ✅ 通過 | 本輪第一層核准者、申請人本人皆排除 |
| T11 | 認領後不再通知無權處理者 | ✅ 通過 | 另一位圖管人員待辦歸零；尚未送出的推播於發送前改為略過 |
| T12 | 代理有效及失效 | ✅ 通過 | 有效：代理人有待辦且收推播；撤銷、過期：不再有 |
| T13 | App 開啟時更新 | ✅ 通過 | Chromium：登入後 `setAppBadge(n)`，n＝資料庫計數 |
| T14 | 返回前景時更新 | ✅ 通過 | Chromium：背景期間新增案件，回前景後角標更新 |
| T15 | 登出清除 | ✅ 通過 | `clearAppBadge`、導覽列數字消失；換帳號只顯示新帳號計數 |
| T16 | 不支援 Badging API | ✅ 通過 | 移除 API 後顯示說明、App 內計數正常、無錯誤 |
| T17 | Push 失敗不影響操作 | ✅ 通過 | 後端：佇列寫入故障時核准仍提交並留下錯誤紀錄；瀏覽器：發送端回 500 時正式送件仍成功 |
| T18 | 重複事件不重複推播 | ✅ 通過 | 同一待辦狀態重複更新不再排入；發送批次鎖定後不會被重複取出 |
| T19 | 無效訂閱處理 | ✅ 通過 | 410 → 停用；之後不再取出；無有效訂閱 → SKIPPED |
| T20 | 通知點擊開啟正確路由 | ✅ 通過（模擬） | Chromium：CDP 送入推播 → 通知 `#/r/<id>`、角標 7、App 收到同步訊息；外部網址改為 `#/my`；**點擊以合成事件呼叫處理程序**（無法以程式點擊系統通知） |
| T21 | Chromium 桌面及手機模擬 | ✅ 通過 | 桌面 1366、Pixel 7 |
| T22 | WebKit 手機模擬 | ✅ 通過 | iPhone 13（iOS 15 設定檔：顯示需 16.4）；iOS 17 UA 未加入主畫面：顯示須加入主畫面、不要求權限 |
| T23 | V5.8／V5.9 關鍵流程回歸 | ✅ 通過 | 見上表 |
| T24 | LOGO／manifest／icon | ✅ 通過 | manifest 無錯誤；五種圖示尺寸正確；HTML 引用正確；SW 預先快取 |
| T25 | iPhone Safari 真實裝置 | ⬜ **未測** | 無實機 |
| T26 | Android Chrome 真實裝置 | ⬜ **未測** | 無實機 |

### 3.2 推播四個階段的驗證範圍

| 階段 | 隔離環境驗證 | 說明 |
|---|---|---|
| 事件已產生（排入佇列） | ✅ | 後端測試 |
| 推播服務接受 | ✅（假推播服務） | 加密內容可被獨立實作解密、VAPID 簽章有效；**未連線真實 FCM／Apple** |
| 裝置收到 | ⚠️ 部分 | Chromium 以 CDP 直接送入 Service Worker；**未經真實推播服務** |
| 角標已更新 | ⚠️ 部分 | 驗證 `setAppBadge` 呼叫與數字；**無頭瀏覽器沒有桌面圖示，未觀察到實際圖示** |

另：Chromium 按「啟用通知」可取得權限，但建立瀏覽器訂閱失敗（`Registration failed - permission denied`，隔離環境無法連線 FCM），畫面如實顯示錯誤；**真實訂閱流程需實機驗證**。

## 4. 權限與安全影響

| 項目 | 結果 |
|---|---|
| 既有 RLS、RPC、角色、權限 | 未修改任何既有函式或政策（只新增） |
| 新資料表 | `app.push_subscriptions／push_outbox／push_deliveries／push_enqueue_errors`：RLS 啟用、`anon`／`authenticated` 無權限 |
| 新 RPC | 全部 `SECURITY DEFINER`＋`search_path = ''`；員工函式只授予 `authenticated`，發送端函式只授予 `service_role` |
| 前端指定員工 | 不可能：所有員工函式無員工參數 |
| 管理員假冒員工 | 管理員只能查看發送摘要，無法登記他人訂閱或讀取 endpoint |
| SSRF | 資料庫與發送端雙重允許清單（HTTPS、無帳密、無連接埠、限定推播服務主機）；不跟隨轉址；10 秒逾時；資料庫遭寫入內部位址時不連線並停用 |
| 秘密 | VAPID 私鑰、排程密鑰只在 Supabase Secrets／Vault；程式碼、日誌、回傳值、發送紀錄皆不含 endpoint、金鑰、通知內容 |
| 交易 | 推播寫入失敗不回滾業務交易；發送在交易外進行 |
| safeupdate | 所有新 UPDATE／DELETE 皆含 WHERE |
| Service Worker 快取 | 未新增快取項目；仍只快取本站靜態檔，不快取 Supabase 資料 |

## 5. 未完成、限制與風險

| 項目 | 說明 |
|---|---|
| T25、T26 實機 | 未測。iPhone 角標、背景通知、Android 通知顯示須依 `docs/release-v591.md` 第 5 節實測 |
| Edge Function 執行環境 | `index.ts` 未在 Deno／Supabase Edge 實際執行（本環境無法安裝 Deno）；其核心 `dispatch.ts`、`webpush.ts` 已以 Node 22 執行測試並通過型別檢查 |
| 正式 Supabase／PostgREST | 以 shim 與本機橋接模擬（測試過程發現並修正橋接一處與 PostgREST 不同的行為：`setof` 純量回傳格式） |
| 只在「待辦增加」時推播 | 待辦減少（他人已處理、認領）不另外推播，iPhone 角標會在下次開啟 App 或下一則推播時更新 |
| 未觸發推播的情境 | 新建代理、角色或部門管轄異動不會立即推播（對應員工開啟 App 時角標會正確） |
| Android 角標 | 依手機品牌顯示數字、圓點或不顯示，不能保證數字；App 內數字為準 |
| 推播延遲 | 最佳努力遞送；斷網、省電模式、系統排程可能延遲或合併 |
| 排程重試 | 需另行啟用 `pg_cron`＋`pg_net`（發布文件第 3 節第 5 步）；未設定時，重試要等到下一次有人完成操作 |
| 測試工具變更 | `tests/local/v59/bridge/bridge.mjs` 新增 push-dispatch 測試替身並修正上述 `setof` 格式；V5.9 測試以修正後橋接重跑仍全部通過 |

## 6. 上線前補強（2026-11-27 第二輪）

只修正有實際風險的部分；未修改既有案件流程，因此只執行直接相關的測試（後端 82、發送端 21、瀏覽器 40、safeupdate、TypeScript／ESLint／Build）。

### 6.1 發現與修正

| 風險 | 原狀況 | 修正 | 證據 |
|---|---|---|---|
| 待辦類別改變仍送舊通知 | 發送前只檢查「仍有任一待辦」，第一層通知在案件轉第二層後仍可能送出（兼任圖管主管者） | 發送前須「仍為同一類別」才送，否則略過 | Q1：以舊條件執行失敗、新條件通過 |
| 金鑰設定錯誤導致佇列卡住 | 簽章失敗在回報前拋出，佇列停在「發送中」並無上限重試 | ① 簽章錯誤回報為失敗，走退避與 5 次上限；② 取出前檢查金鑰格式、配對與 `VAPID_SUBJECT`，錯誤時回 503 不取出；③ 鎖逾時且已達 5 次的「發送中」改為 FAILED | V1–V6、Q7 |
| `VAPID_SUBJECT` 格式 | 未檢查 | 只接受 `mailto:` 信箱或 `https:` 網址 | V4、V5 |

### 6.2 檢查結果

| 項目 | 結果 | 證據 |
|---|---|---|
| 收件人失去權限（代理撤銷）後不送 | ✅ | Q2 |
| 排入後帳號停用／重設密碼不送 | ✅ | Q3、Q4 |
| 同一手機 A → B：A 的通知不送到 B 的手機；B 自己的會送 | ✅ | Q5 |
| 訂閱停用失敗但工作階段已失效：後端仍不送 | ✅ | Q6、S10 |
| 重複事件不重複送 | ✅ | T18、D2（既有） |
| 登出清除角標、換帳號只顯示自己的計數 | ✅ | 瀏覽器 T15 |
| 推播失敗不影響案件操作 | ✅ | T17（後端＋瀏覽器） |
| 排程（`pg_cron`＋`pg_net`）相容性 | ✅ 文件審查 | 函式以 `x-push-cron-secret` 驗證、需 `verify_jwt = false`；SQL 不含密鑰、從 Vault 讀取；**未在任何環境建立排程** |

### 6.3 已知延遲（未實作即時同步，不宣稱已完成）

| 情境 | 目前行為 |
|---|---|
| 新增待辦（第一層／第二層待審、退回、待發行、待簽收、整案異常） | App 關閉時觸發背景推播並更新角標（需實機驗證送達） |
| 待辦減少（他人已處理、被他人認領、案件完成） | **不推播**；App 下次開啟或回到前景時更新；iPhone 圖示角標在此之前會顯示較大的數字 |
| 新增或撤銷代理、角色或管轄部門異動 | **不推播**；當事人開啟 App 時計數正確 |
| 通知標記已讀 | App 內立即更新（已讀只能在 App 內操作） |

### 6.4 其他限制與風險

| 項目 | 說明 |
|---|---|
| 離線登出 | 登出時若完全無網路，伺服器端工作階段未撤銷，該手機在下一位使用者登入（重新登記裝置）前，仍可能收到前一位使用者的一般性提示（內容不含案件資料） |
| 重複送達 | 若推播服務已接受、但回報資料庫失敗，2 分鐘後可能再送一次（至少一次送達；同一 `Topic` 由推播服務合併） |
| 舊版 API 金鑰期限 | `push-dispatch` 與正式的 `admin-accounts` 相同，讀取 `SUPABASE_SERVICE_ROLE_KEY`／`SUPABASE_ANON_KEY`。Supabase 文件說明舊版金鑰保留至 2026 年底；停用前兩個函式都須改讀 `SUPABASE_SECRET_KEYS`／`SUPABASE_PUBLISHABLE_KEYS`（另案處理） |
| Deno 實際執行 | `index.ts` 仍未在 Deno／Supabase Edge 執行；核心模組已以 Node 22 測試 |
| 實機 | T25 iPhone、T26 Android 仍未測 |

## 7. 套件安全更新與本機預覽（2026-11-27 第三輪）

### 7.1 套件更新（同一大版本內、固定版本號；未使用 `npm audit fix`）

| 套件 | 原版本 | 新版本 | 是否進入正式網站 | 處理的問題 |
|---|---|---|---|---|
| `react-router-dom` | 6.26.2 | 6.30.6 | 是 | 高風險：不受信任路徑的外部轉址 |
| `fflate` | 0.8.2 | 0.8.3 | 是（管理員 Excel 匯入） | 中風險：異常 ZIP64 檔案可能無限迴圈 |
| `@supabase/supabase-js` | 2.45.4 | 2.50.0 | 是 | 低風險：auth-js 異常路徑（選擇最小修正版，避免 2.119 的大幅變動） |
| `vite`、`@vitejs/plugin-react` | 5.4.10、4.3.2 | 5.4.21、4.7.0 | 否（開發工具） | 開發伺服器相關 |
| `vitest` | 2.1.3 | 2.1.9 | 否 | 測試工具 |
| `eslint`、`@eslint/js`、`typescript-eslint` | 9.13.0、9.13.0、8.11.0 | 9.39.5、9.39.5、8.74.0 | 否 | 檢查工具（ESLint 9.13 已停止支援） |

結果：漏洞 **20 → 9**（重大 2、高 1、中 6、低 0）。剩餘項目都需要升級大版本（vite 8、vitest 5、react-router 7），不在本次範圍：

| 剩餘 | 影響 | 說明 |
|---|---|---|
| vite／esbuild／vite-node | 只在本機開發 | 開發伺服器執行期間的風險；正式網站為靜態檔案，不含開發伺服器 |
| vitest／tinypool／@vitest/mocker | 只在測試工具 | 專案平時不啟動 vitest；CI 也未執行 |
| react-router（中） | 正式網站 | 需 `<Link>`／`navigate()` 使用不受信任的目標才會發生；程式中所有導覽目標皆為內部固定路徑或案件 UUID，推播點擊路由另有白名單 → 實際暴露極低 |

### 7.2 更新後回歸

| 測試 | 結果 |
|---|---|
| `npm run check`（型別檢查＋ESLint）、建置、推播模組型別檢查 | ✅ |
| V5.8 回歸 | ✅ 9/9 |
| V5.9 端對端（Excel 匯入使用 fflate、登入使用 supabase-js、路由） | ✅ 16/16 |
| V5.9 手機版面＋錯誤檔／WebKit 產品搜尋 | ✅ 19/19、25/25 |
| V5.9.1 瀏覽器 | ✅ 40/40 |
| pages 模式建置連正式 Supabase（未登入、唯讀）：連線、公開註冊關閉、未登入讀不到資料、桌面／iPhone／Android 登入畫面、Console、Service Worker | ✅ 32/32 |

### 7.3 本機環境發現

- 本機 `npm run dev` 不讀取 `.env.local`，而是連到本機 API（`127.0.0.1:54329`，需 Linux＋Docker）；在 Windows 會無法登入。
- 連正式 Supabase 的本機方式為 `npm run build -- --mode pages` 後 `npm run preview`；建置時會檢查 `.env.local`（網址須為本專案、金鑰須為本專案公開金鑰），錯誤即拒絕建置（已驗證正、反兩種情況）。
- 新增 `本機預覽.cmd`（雙擊執行上述流程，並在套件版本不符時自動重新安裝）。**此檔未在 Windows 實際執行**（本環境為 Linux），需於使用者電腦確認一次。
- 登入頁文字為「帳號由系統管理員建立；忘記密碼請洽系統管理員重設」，與 `AGENTS.md` 規定的「忘記密碼請聯絡系統管理員」不完全相同（V5.8 既有內容，未修改，待使用者決定）。

## 8. 正式部署紀錄：步驟 1–3（2026-11-27，經使用者授權）

| 步驟 | 內容 | 結果 |
|---|---|---|
| 發布前核對（唯讀） | migration 30 筆、最新 `v59_product_master_safeupdate`；migration 032 依賴的 10 個函式（`l1_authority`、`has_role`、`require_employee` 等）與 repo 版本 md5 完全相同；`personal_security_notices` 欄位相同；尚無 V5.9.1 物件 | ✅ |
| 1. 套用 migration 032 | `v591_badge_and_push`（版本 `20261127051332`），內容與 commit `ca0a7df` 的檔案相同；migration 紀錄 30 → 31 | ✅ |
| 2. 權限核對 | 4 張新表 `anon`／`authenticated` 無權限、RLS 啟用；員工函式僅 `authenticated`、發送端僅 `service_role`、內部函式無人可直接執行；全部 `search_path=''`；`write_r8_application` 仍無 `authenticated` 直接執行權；safeupdate 掃描 0 筆；7 位啟用員工角標皆可計算；安全建議無新類別 | ✅ |
| 3. 部署 `push-dispatch` | 版本 1、ACTIVE、`verify_jwt=false`；檔案與 commit `ca0a7df` 相同 | ✅ |
| 部署後檢查（不會發送） | OPTIONS 200；GET 回 `publicKey: null`（尚未設定 Secrets）；未登入、錯誤排程密鑰、偽造 JWT 皆 401；PUT 405；佇列／訂閱／發送紀錄／錯誤皆 0；函式日誌無錯誤。**`index.ts` 已在 Supabase Edge（Deno）實際執行** | ✅ |

**未執行（需另行授權或由維護人員操作）**：Secrets（VAPID 金鑰、`VAPID_SUBJECT`、`PUSH_CRON_SECRET`）、Vault、排程、合併前端與部署網站、實機驗收。

**目前正式環境狀態**：案件異動時會依權限排入推播佇列，但因尚無任何裝置訂閱（新前端未上線）且未設定 Secrets，不會發送任何推播。既有 V5.9 網站不呼叫新函式，行為不變。回復方式見 `docs/release-v591.md` 第 4 節（此時只需執行第 3、4 步：刪除函式與回復 SQL）。

## 9. 上線前最後修正（2026-11-27）

| 項目 | 修改 | 測試 |
|---|---|---|
| 登入頁文字 | 依 `AGENTS.md` 1.3 改為只顯示「忘記密碼請聯絡系統管理員」 | C12 ✅ |
| 推播尚未設定時的畫面 | 伺服器未設定 Secrets（`GET push-dispatch` 回 `publicKey: null`）時，不顯示會失敗的「啟用通知」按鈕，改顯示「背景通知尚未開放」；App 內計數不受影響 | C11 ✅ |

回歸：V5.9.1 瀏覽器 42/42、V5.8 9/9、V5.9 e2e 16/16、型別檢查／ESLint／建置 ✅。

## 10. 上線後問題：管理員設定部門主管出現「權限不足」（2026-11-27）

- **原因**：正式資料庫 8 個 RPC 的 `authenticated` 執行權限在 migration 紀錄之外被移除（11/26 前即已存在，非 V5.9／V5.9.1 migration 造成）：`admin_set_roles`、`admin_set_manager_departments`、`admin_update_employee`、`admin_upsert_department`、`admin_create_delegation`、`admin_revoke_delegation`、`admin_release_claim`、`cancel_request`。日誌錯誤：`permission denied for function admin_set_roles`（42501）。
- **修正**：migration 034 `v591_restore_rpc_grants` 恢復與 repo 定義相同的授權（只授予 `authenticated`，不授予 `anon`）；各函式內仍驗證 SYS_ADMIN／本人。
- **驗證**：以 repo 全部 migration 建立的隔離資料庫為基準，比對正式環境 public schema 63 個函式的 `anon`／`authenticated` 執行權限：修正前 8 項不同、修正後 **0 項不同**。
