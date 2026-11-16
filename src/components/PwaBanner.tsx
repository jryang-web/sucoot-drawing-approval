import { applyUpdate, usePwa } from "../lib/pwa";

// 頁面頂端的提示列：新版本可更新、目前離線
export default function PwaBanner() {
  const { updateReady, online } = usePwa();
  if (!updateReady && online) return null;
  return (
    <div className="pwa-banner" role="status">
      {!online && <span>目前離線：畫面可開啟，但資料無法讀取或送出</span>}
      {online && updateReady && (
        <>
          <span>系統有新版本</span>
          <button className="primary" onClick={applyUpdate}>立即更新</button>
        </>
      )}
    </div>
  );
}
