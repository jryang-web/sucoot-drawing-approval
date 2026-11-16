import { useState } from "react";
import { isIOS, isLineApp, isStandalone, promptInstall, usePwa } from "../lib/pwa";

// 安裝到主畫面：Android/桌機用系統安裝視窗；iOS 顯示「分享 → 加入主畫面」說明；LINE 內建瀏覽器提示改用外部瀏覽器
export default function InstallHint() {
  const { canInstall } = usePwa();
  const [open, setOpen] = useState(false);
  if (isStandalone()) return null;

  if (canInstall) return <button className="linkbtn" onClick={promptInstall}>安裝 App</button>;
  if (!isIOS && !isLineApp) return null;

  return (
    <>
      <button className="linkbtn" onClick={() => setOpen(!open)}>安裝 App</button>
      {open && (
        <div className="install-help">
          {isLineApp ? (
            <>LINE 內建瀏覽器無法安裝。請點右上角「⋯」選擇<strong>以預設瀏覽器開啟</strong>（iPhone 為 Safari、Android 為 Chrome），再安裝。</>
          ) : (
            <>iPhone／iPad：請用 <strong>Safari</strong> 開啟，點下方<strong>分享按鈕</strong>（方框加向上箭頭），選擇<strong>「加入主畫面」</strong>。</>
          )}
        </div>
      )}
    </>
  );
}
