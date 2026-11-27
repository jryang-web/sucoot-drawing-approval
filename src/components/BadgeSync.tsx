// V5.9.1：登入後掛載；負責在各同步時機重新取得角標，並處理 service worker 的推播訊息
import { useEffect } from "react";
import { badgeRefreshEvent, refreshBadge, startBadge } from "../lib/badge";
import { kickPushDispatch, syncPushAfterLogin } from "../lib/push";
import { resultEvent } from "../lib/operations";

const ROUTE = /^#\/(my|r\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;

export default function BadgeSync({ employeeId }: { employeeId: string }) {
  useEffect(() => {
    void startBadge(employeeId);          // 登入成功／開啟 PWA
    void syncPushAfterLogin();            // 已允許通知的裝置：靜默登記到目前帳號

    const onVisible = () => { if (document.visibilityState === "visible") void refreshBadge(false); };
    const onNetwork = () => void refreshBadge();
    const onOperation = () => { kickPushDispatch(); void refreshBadge(); };   // 完成案件操作
    const onRequest = () => void refreshBadge();                                // 通知已讀、工作首頁
    const onWorker = (e: MessageEvent) => {
      if (e.data?.type === "SUCOOT_BADGE_REFRESH") void refreshBadge();
      if (e.data?.type === "SUCOOT_NAVIGATE" && typeof e.data.hash === "string" && ROUTE.test(e.data.hash)) window.location.hash = e.data.hash;
    };
    const timer = window.setInterval(() => { if (document.visibilityState === "visible") void refreshBadge(false); }, 5 * 60 * 1000);

    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("pageshow", onVisible);
    window.addEventListener("online", onNetwork);
    window.addEventListener("offline", onNetwork);
    window.addEventListener(resultEvent, onOperation);
    window.addEventListener(badgeRefreshEvent, onRequest);
    navigator.serviceWorker?.addEventListener("message", onWorker);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("pageshow", onVisible);
      window.removeEventListener("online", onNetwork);
      window.removeEventListener("offline", onNetwork);
      window.removeEventListener(resultEvent, onOperation);
      window.removeEventListener(badgeRefreshEvent, onRequest);
      navigator.serviceWorker?.removeEventListener("message", onWorker);
    };
  }, [employeeId]);
  return null;
}
