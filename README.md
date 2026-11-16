# sucoot-drawing-approval
SUCOOT 圖面申請、雙層審核與 LINE 通知管理系統（V5.7 第一階段，**測試版**）

## 版本紀錄
| 版本 | 日期 | 內容 |
|---|---|---|
| v0.1.1 | 2026-11-16 | 標題加註「測試版」；頁尾顯示版本號與建置資訊；新增「版本說明」頁（顯示本文件） |
| v0.1.0 | 2026-11-16 | 第一階段：員工登入與首次改密碼、圖面申請（多筆圖號）、部門主管第一層審核、圖管主管第二層審核、圖管認領與發行、簽收、個別圖號異常與補發、代理審核、認領重新指派、負責人移交、逾期標記、管理者後台（部門／員工帳號／角色／管轄／稽核）；依角色保護頁面 |

## 使用方式
- 網址：https://jryang-web.github.io/sucoot-drawing-approval/
- 以「員工編號＋密碼」登入；帳號由系統管理員建立，首次登入須修改密碼
- 忘記密碼請洽系統管理員重設

## 流程
1. 申請人建立申請（可多筆圖號）並送出 → **第一層待審**
2. 所屬部門主管核准 → **第二層待審**（可退回、拒絕、調降急件）
3. 圖管主管核准 → **待發行**（第一層與第二層不可為同一人）
4. 圖管人員認領 → 將圖面上傳至 LINE 群組 → 登記發行 → **待簽收**
5. 申請人確認整案收到 → **已完成**；個別圖號有問題可回報異常，圖管人員只補發該圖號
6. 發行後三個工作日（週一至週五，不含發行當天）未簽收，標記「簽收逾期」

## 架構
- 前端：React 18 + TypeScript + Vite + HashRouter（可部署 GitHub Pages，`base: "./"`）
- 後端：Supabase（專案 `sucoot-drawing-dev` / `qifjiaxskortyennnpsh`，首爾）
  - PostgreSQL + RLS：前端只有 **SELECT**（由 RLS 限制可見範圍），**所有寫入都經由 SECURITY DEFINER RPC**
  - Edge Function `admin-accounts`：建立帳號、重設密碼、啟用／停用、本人改密碼（service_role key 只存在 Supabase 平台）
- 登入：員工編號 → `小寫員工編號@login.sucoot.com` → Supabase Auth。公開註冊已關閉。

## 目錄
| 路徑 | 說明 |
|---|---|
| `supabase/migrations/` | 0001 組織/角色/稽核 · 0002 管理 RPC · 0003 申請/審核/發行/簽收/異常/代理/移交 · 0004 第一位管理者初始化 · 0005 權限收斂 · 0006 只讀授權 |
| `supabase/functions/admin-accounts/` | 帳號管理 Edge Function |
| `supabase/tests/business_flow.sql` | 業務流程自動化測試（88 項，交易內執行並完整回滾） |
| `tests/integration/` | 帳號流程整合測試（需測試專用管理者帳號） |
| `src/` | 前端 |
| `docs/` | 第一階段報告與測試結果 |

## 開發
```bash
npm install
npm run dev
```
`.env.example` 列出可覆寫的變數；預設連線 dev 專案（publishable key 可公開）。**不可**在前端放 secret / service_role key。

## 測試
- 資料庫層：將 `supabase/tests/business_flow.sql` 在 SQL Editor 執行，結果以 `TEST_RESULT {...}` 例外訊息回傳，不留下資料。
- 帳號流程：`TEST_ADMIN_EMPLOYEE_NO=... TEST_ADMIN_PASSWORD=... npm run test:integration`

## 角色
一般員工（EMPLOYEE，所有人都有）、部門主管（DEPT_MANAGER＋管轄部門）、圖管主管（DRAWING_MANAGER）、圖管人員（DRAWING_STAFF）、系統管理員（SYS_ADMIN）。
部門、員工帳號、角色、管轄與代理，全部由系統管理員在系統內設定。
