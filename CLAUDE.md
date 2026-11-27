# CLAUDE.md — SUCOOT 圖面申請與審核系統

本專案的業務規則、權限與授權原則都在 **`AGENTS.md`**，工作前必須先閱讀並遵守：

@AGENTS.md

## 專案快速資訊

- 正式網站：https://jryang-web.github.io/sucoot-drawing-approval/（`main` 合併後由 GitHub Actions 自動部署）
- 正式 Supabase：`sucoot-drawing-dev`（`qifjiaxskortyennnpsh`）
- 技術：React、TypeScript、Vite、HashRouter、Supabase（PostgreSQL、RLS、SECURITY DEFINER RPC、Edge Functions）、PWA
- 所有回報使用繁體中文（台灣用語）；使用者可見與稽核時間採台灣時間 `YYYY-MM-DD HH:MM:SS`

## 常用指令

```bash
npm ci
npm run check                 # 型別檢查＋ESLint
npm run build                 # 本機建置（連本機 API）
npm run build -- --mode pages # 正式網站建置（讀取 .env.local，並檢查網址與金鑰屬於本專案）
```

- 隔離測試：見 `tests/local/v59/README.md`、`tests/local/v591/README.md`（本機 PostgreSQL＋Supabase 模擬，不連正式環境）。
- Windows：`npm run dev` 需要 Linux＋Docker 本機後端，無法登入；請雙擊 `本機預覽.cmd`。

## 工作原則摘要（詳見 AGENTS.md）

- 修改程式、推送 GitHub、變更 Supabase、部署前須取得使用者授權；先在分支與隔離環境測試。
- 正式資料庫變更一律以 `supabase/migrations/` 記錄；所有 `UPDATE`／`DELETE` 須有 `WHERE`（正式啟用 safeupdate）。
- 不得產生、讀取或輸出正式金鑰與 Secrets；不得在程式、日誌或聊天中出現密碼或金鑰。
- 規格與發布紀錄：`docs/release-*.md`、`docs/*-test-report.md`。
