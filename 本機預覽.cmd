@echo off
rem SUCOOT V5.9.1 本機預覽：雙擊即可執行，不需要開 PowerShell。
rem 連線 .env.local 指定的 Supabase（正式資料庫）：請只檢視，不要送件、審核或匯入。
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title SUCOOT 本機預覽
echo.
echo ===== SUCOOT 圖面申請 本機預覽 =====
echo 注意：此預覽連線正式資料庫，登入後請只檢視，不要送件、審核或匯入 Excel。
echo.
if not exist ".env.local" (
  echo [錯誤] 找不到 .env.local，請先建立（需要 VITE_SUPABASE_URL 與 VITE_SUPABASE_PUBLISHABLE_KEY）。
  goto fail
)
where npm.cmd >nul 2>&1 || (
  echo [錯誤] 找不到 npm，請先安裝 Node.js。
  goto fail
)
if not exist "node_modules" (
  echo [準備] 第一次使用，安裝套件中，約需 1 分鐘…
  call npm.cmd ci --no-audit --no-fund || goto fail
) else (
  call npm.cmd ls --depth=0 >nul 2>&1 || (
    echo [準備] 套件版本已更新，重新安裝中，約需 1 分鐘…
    call npm.cmd ci --no-audit --no-fund || goto fail
  )
)
echo [1/2] 建置中（同時檢查 .env.local 是否為正確的 Supabase 專案）…
call npm.cmd run build -- --mode pages || (
  echo [錯誤] 建置失敗。若訊息提到「Pages 建置需要」，代表 .env.local 的網址或金鑰不正確。
  goto fail
)
echo.
echo [2/2] 啟動預覽並開啟瀏覽器：http://127.0.0.1:4173/
echo 要結束時，直接關閉這個視窗即可。
echo.
call npm.cmd run preview -- --host 127.0.0.1 --port 4173 --strictPort --open || (
  echo [錯誤] 預覽無法啟動。若訊息提到 port 4173，代表已有另一個預覽在執行，請先關閉它的視窗。
  goto fail
)
goto end
:fail
echo.
echo 未完成。請把這個視窗的畫面截圖提供給開發人員（畫面不會顯示任何金鑰）。
pause
exit /b 1
:end
endlocal
