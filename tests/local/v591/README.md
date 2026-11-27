# V5.9.1 隔離測試（角標與背景推播）

只使用本機隔離 PostgreSQL（`tests/local/v59/setup.sh`）、本機 API 橋接與本機假推播服務，**不連線正式 Supabase、不對任何真實裝置發送推播**。

| 檔案 | 內容 |
|---|---|
| `../v591_badge_push.sql` | 後端 82 項：角標計數、多角色去重、部門管轄、代理有效／撤銷／過期、跨層核准排除、認領、權限、停用／重設密碼、訂閱驗證（SSRF）、佇列去重、失敗不回滾、重試與失效訂閱（交易內執行並回滾） |
| `push-dispatch.test.mts` | 發送端 21 項：以獨立實作 `http_ece` 解密、Node crypto 驗證 VAPID 簽章；410 停用、500 重試、連線失敗、5 次上限、內部位址阻擋、VAPID 配對與 subject 格式 |
| `ui.cjs` | 瀏覽器 40 項：Chromium 桌面／Android 模擬、WebKit iPhone 模擬；角標同步時機、登出清除、不支援 Badging API、離線標示、Service Worker 推播與通知點擊、manifest／圖示、管理員推播紀錄 |
| `shims.d.ts`、`tsconfig.json` | 測試與 Edge Function 共用模組的型別檢查 |

```bash
export PGHOST=/var/lib/postgresql/sucoot-v59/run PGPORT=54330 PGUSER=postgres PGDATABASE=postgres
(cd tests/local/v591 && npm install) && (cd tests/local/v59/bridge && npm install)
export TEST_VAPID_PUBLIC_KEY=<執行時隨機產生的測試公鑰>
bash tests/local/v59/regress.sh "$PWD" v5.9.1          # 重建資料庫＋V5.8 回歸＋啟動橋接
psql -v ON_ERROR_STOP=1 -f tests/local/v591_badge_push.sql
node tests/local/v591/push-dispatch.test.mts
npm run build && npx vite preview --host 127.0.0.1 --port 4173 &
PLAYWRIGHT_BROWSERS_PATH=<含 chromium 與 webkit 的資料夾> node tests/local/v591/ui.cjs <輸出資料夾>
npx tsc -p tests/local/v591/tsconfig.json
```

Chromium 需以完整版新無頭模式（`channel: "chromium"`）執行，headless shell 不支援通知 API。
