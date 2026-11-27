// V5.9.1：工作首頁「通知與角標」卡片（App 內計數、同步狀態）；「設定」分頁的背景通知開關（PushSettings）
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useBadge } from "../lib/badge";
import { disablePushHere, enablePush, pushConfigured, pushEnabledHere, pushSupport, type PushBlocker } from "../lib/push";
import { isIOS } from "../lib/pwa";
import { fmt } from "../lib/labels";

const BLOCKER: Record<PushBlocker, string> = {
  insecure: "需以 HTTPS 開啟才能使用通知。",
  "line-app": "LINE 內建瀏覽器不支援通知，請改用 Safari 或 Chrome 開啟。",
  "ios-version": "iPhone 需 iOS 16.4 以上才支援 App 通知。",
  "ios-not-installed": "iPhone 須先以 Safari「加入主畫面」，再從主畫面開啟 SUCOOT，才能啟用通知。",
  "no-service-worker": "此瀏覽器不支援背景通知。",
  "no-push": "此瀏覽器不支援背景通知。",
};

export function NotificationSettings() {
  const badge = useBadge();
  const count = (n: number | null) => (n === null ? "—" : String(n));
  return <section className="r8-card" aria-label="通知與角標">
    <h2>通知與角標</h2>
    <div className="r8-metrics">
      <div className="r8-meter"><strong>{count(badge.unread)}</strong>未讀通知</div>
      <div className="r8-meter"><strong>{count(badge.pending)}</strong>待辦案件</div>
      <div className="r8-meter"><strong>{count(badge.total)}</strong>角標合計</div>
    </div>
    <p className="r8-muted" role="status">
      {badge.offline ? `目前離線，以上為 ${badge.syncedAt ? fmt(badge.syncedAt) : "—"} 的資料，恢復連線後會自動更新。`
        : badge.error ? "暫時無法更新計數，稍後會自動重試。"
        : badge.syncedAt ? `最後同步：${fmt(badge.syncedAt)}` : "同步中…"}
    </p>
    {badge.appBadge !== "supported" && <p className="r8-muted">
      {badge.appBadge === "unsupported" ? "此瀏覽器不支援 App 圖示角標，請以本頁數字為準。"
        : isIOS ? "iPhone 圖示角標需先允許通知，並在「設定 > 通知 > SUCOOT」開啟「標記」。" : "圖示角標未能更新，請以本頁數字為準。"}
    </p>}
    <p className="r8-muted">背景通知的啟用與停用，請到「<Link to="/password">設定</Link>」分頁。</p>
  </section>;
}

export function PushSettings() {
  const [support] = useState(pushSupport);
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [configured, setConfigured] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    pushEnabledHere().then((v) => { if (active) setEnabled(v); }).catch(() => { if (active) setEnabled(false); });
    if (support.supported) pushConfigured().then((v) => { if (active) setConfigured(v); });
    return () => { active = false; };
  }, [support.supported]);

  async function enable() {
    setBusy(true); setMessage(null);
    try {
      const r = await enablePush();
      setEnabled(r === "enabled");
      setMessage(r === "enabled" ? "已啟用此裝置的通知。" : r === "denied"
        ? "通知權限已被拒絕，請到裝置的設定中允許 SUCOOT 通知後再試。" : "尚未允許通知。");
    } catch (e) { setMessage(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }
  async function disable() {
    setBusy(true); setMessage(null);
    try { await disablePushHere(); setEnabled(false); setMessage("已停用此裝置的通知。"); }
    catch (e) { setMessage(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  }

  return <section className="r8-card" aria-label="背景通知">
    <h2>背景通知</h2>
    {!enabled && <p><b>建議開啟，才能收到通知。</b></p>}
    {enabled ? <p>此裝置已啟用通知：有新的待辦時會收到通知並更新角標。</p>
      : !support.supported ? <p className="r8-muted">{BLOCKER[support.blocker!]}</p>
      : support.permission === "denied" ? <p className="r8-muted">此裝置已拒絕 SUCOOT 通知；請到裝置或瀏覽器設定中允許通知。</p>
      : configured === false ? <p className="r8-muted">背景通知尚未開放，系統管理員完成設定後即可在此啟用。App 內的待辦與未讀數字不受影響。</p>
      : <p className="r8-muted">啟用後，App 未開啟時也會在有新待辦時收到通知（實際送達時間依手機網路與省電設定而定）。</p>}
    {/* 開關一律顯示；此裝置無法使用時停用並以上方文字說明原因 */}
    {enabled ? <button className="r8-btn" disabled={busy} onClick={disable}>停用此裝置通知</button>
      : <button className="r8-btn r8-primary" onClick={enable}
          disabled={busy || !support.supported || support.permission === "denied" || configured !== true || enabled === null}>啟用通知</button>}
    {isIOS && <p className="r8-muted">iPhone：需 iOS 16.4 以上、從主畫面開啟 SUCOOT、允許通知，並在「設定 &gt; 通知 &gt; SUCOOT」開啟「標記」。</p>}
    {message && <p role="alert">{message}</p>}
  </section>;
}
