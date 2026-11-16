# SUCOOT V5.7｜第一階段 實作與測試結果

- 日期：2026-11-16
- 環境：Supabase `sucoot-drawing-dev`（`qifjiaxskortyennnpsh`，ap-northeast-2）
- 未部署正式環境；未部署 GitHub Pages

## 1. 已套用到 Supabase 的變更
| 項目 | 內容 |
|---|---|
| Migration 0001 `core_org` | departments、employees、employee_roles、manager_departments、admin_audit_logs、helper、RLS；收回 `rls_auto_enable()` 的 API 執行權限 |
| Migration 0002 `admin_rpc` | `me`、部門／員工／角色／管轄管理 RPC；`svc_*`（僅 service_role） |
| Migration 0003 `drawing_requests` | 申請、雙層審核、認領發行、簽收、異常補發、代理、移交、警示、`v_requests`（含逾期標記） |
| Migration 0004 `bootstrap_admin` | 綁定已手動建立的 `admin@login.sucoot.com`：員工 `admin`、管理部、SYS_ADMIN |
| Migration 0005 `hardening` | anon 不可執行任何函式；固定 search_path |
| Migration 0006 `select_grants` | 授予 authenticated 只讀（本專案預設不授權），anon 無任何資料表權限 |
| Edge Function `admin-accounts` v1 | create_account / reset_password / set_active / change_own_password |

## 2. 測試結果
### 2.1 自動化測試通過（資料庫層，`supabase/tests/business_flow.sql`，88/88）
以真實 `authenticated` 角色＋JWT `sub` 執行 RPC，測試身分為交易內的臨時員工；整個交易回滾，執行後確認資料庫只剩 `admin`。

| 規格測試 | 結果 |
|---|---|
| TEST001 提出申請 | ✅ 自動化通過 |
| TEST003 審核 TEST001 申請 | ✅ 自動化通過（含調降急件＋原因） |
| TEST003 審核自己的申請 | ✅ 自動化通過 |
| TEST007 審核製造部申請 → 拒絕 | ✅ 自動化通過 |
| TEST004 執行第二層審核 | ✅ 自動化通過 |
| TEST004 審核自己的申請（兩層不同人） | ✅ 自動化通過（第一層由管轄圖管部的 TEST007） |
| 同一人嘗試執行兩層審核 → 拒絕 | ✅ 自動化通過 |
| 第一層退回後重新送出 → 回到第一層 | ✅ 自動化通過（輪次 +1） |
| 第二層退回後重新送出 → 回到第一層 | ✅ 自動化通過（原核准保留但失效） |
| 第二層退回未修改但有回覆說明 → 成功 | ✅ 自動化通過 |
| 第二層退回未修改且無回覆說明 → 拒絕 | ✅ 自動化通過 |
| 第一層核准前自行取消 → 成功 | ✅ 自動化通過 |
| 第一層核准後自行取消 → 拒絕 | ✅ 自動化通過 |
| TEST005 認領及發行 | ✅ 自動化通過 |
| TEST004 自行發行 → 拒絕 | ✅ 自動化通過 |
| 管理員解除認領及重新指派 | ✅ 自動化通過（原認領人／接手人／原因／稽核） |
| 多筆圖號僅部分異常 → 只補發異常項目 | ✅ 自動化通過 |
| 異常尚未確認就結案 → 拒絕 | ✅ 自動化通過 |
| 三個工作日未簽收 → 標記逾期 | ✅ 自動化通過（不自動結案） |
| 管理員移交簽收負責人 | ✅ 自動化通過（原申請人保留、唯讀） |
| TEST005 代替申請人簽收 → 拒絕 | ✅ 自動化通過 |
| TEST006 跳過審核直接發行 → 拒絕 | ✅ 自動化通過 |
| 停用帳號嘗試操作業務資料 → 拒絕 | ✅ 自動化通過（資料庫層；既有 session） |

另有：RLS 跨人／跨部門不可見、前端直接 UPDATE 被拒、版本衝突、重複審核／認領／結案、代理（角色、30 天上限、紀錄實際審核者）、不可移除自己的管理員角色、不可停用自己、首次改密碼前業務拒絕、歷史紀錄不可刪除 —— 全部通過。

### 2.2 自動化測試通過（未登入的外部檢查）
| 檢查 | 結果 |
|---|---|
| Edge Function 無 token / 偽造 token | ✅ 401 |
| anon 呼叫 RPC、讀寫資料表 | ✅ 被拒 |
| 公開註冊 signUp | ✅ `signup_disabled` |
| 登入頁（Chromium 桌面＋iPhone 13 模擬） | ✅ 正常顯示、錯誤密碼提示正確、手機無橫向捲動、無 JS 錯誤 |

### 2.3 尚未測試
| 項目 | 原因 |
|---|---|
| Edge Function 實際建立帳號／重設密碼／停用（Auth ban）／本人改密碼 | 需要管理者密碼登入；測試已寫好（`tests/integration/accounts.test.ts`），待提供測試專用管理者 |
| 登入後的各頁面操作（瀏覽器） | 同上 |
| iPhone Safari／Android Chrome／LINE 內建瀏覽器 實機 | 需實機；**手機端尚未驗證**（僅登入頁做過 iPhone 模擬） |

### 2.4 測試失敗
無（首次執行發現「authenticated 無 SELECT 權限」，已以 migration 0006 修正並重跑全數通過）。

## 3. 採用的暫定規則（未正式定案，可修改）
| # | 規則 |
|---|---|
| Q1 | REJECTED 不可取消；DRAFT／第一層待審／RETURNED 可由申請人取消 |
| Q2 | 代理需起訖日、最長 30 天、同一被代理人同層同時段只有一位代理；代理人須具相同角色 |
| Q3 | 補發後簽收期限重新計算（補發日 + 3 工作日） |
| Q4 | 移交後新負責人可查閱、簽收、回報異常；不可修改申請內容；原申請人保留唯讀 |
| Q6 | 案件部門 = 每次送出時申請人的部門 |
| Q7 | 退回（任一層）後「內容未修改」重送時必須填回覆說明；有修改則選填 |
| Q8 | 急件以圖號為單位調降 |
| 初始密碼 | 系統產生 16 碼，只顯示一次；首次登入強制修改 |

## 4. 尚待處理
1. 提供測試專用管理者以執行帳號整合測試與登入後 UI 測試。
2. 手機實機測試（iPhone Safari、Android Chrome、LINE 內建瀏覽器）。
3. Security Advisor：`auth_leaked_password_protection` 未啟用（需 Supabase Pro 方案，Dashboard → Auth → Password security）。
4. 其餘 Advisor 警告為「authenticated 可執行 SECURITY DEFINER RPC」，屬本設計刻意為之（每支 RPC 內部檢查身分與角色）。
5. GitHub Pages 部署、LINE 通知：未進行，待另行核准。
