// V5.9.1：背景 Web Push 裝置訂閱
// - 只有使用者按「啟用通知」才要求瀏覽器通知權限，頁面載入時不會自動詢問
// - 訂閱資料（endpoint、金鑰）只送到後端 push_register，不寫入日誌或錯誤訊息
// - 登入後若此裝置先前已允許通知，靜默重新登記到目前帳號（不再次詢問權限）
// - 登出時停用此裝置於目前帳號的訂閱（瀏覽器端訂閱保留，下次登入可靜默重新登記）
import { supabase } from "./supabase";
import { rpc } from "./api";
import { isIOS, isLineApp, isStandalone, ua } from "./pwa";

export type PushBlocker = "insecure" | "line-app" | "ios-version" | "ios-not-installed" | "no-service-worker" | "no-push";
export interface PushSupport { supported: boolean; blocker?: PushBlocker; permission: NotificationPermission | "unsupported" }

export function iosVersion(): number | null {
  const m = /OS (\d+)[_.](\d+)/.exec(ua);
  return isIOS && m ? Number(m[1]) + Number(m[2]) / 100 : null;
}

export function pushSupport(): PushSupport {
  const permission = typeof Notification === "undefined" ? "unsupported" : Notification.permission;
  const no = (blocker: PushBlocker): PushSupport => ({ supported: false, blocker, permission });
  if (!window.isSecureContext) return no("insecure");
  if (isLineApp) return no("line-app");
  if (isIOS) {
    const v = iosVersion();
    if (v !== null && v < 16.04) return no("ios-version");
    if (!isStandalone()) return no("ios-not-installed");
  }
  if (!("serviceWorker" in navigator)) return no("no-service-worker");
  if (!("PushManager" in window) || typeof Notification === "undefined") return no("no-push");
  return { supported: true, permission };
}

const platform = () => (isIOS ? "ios" : /Android/i.test(ua) ? "android" : "desktop");

async function registration(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  // 開發模式不註冊 service worker；最多等 5 秒
  return Promise.race([navigator.serviceWorker.ready, new Promise<null>((r) => setTimeout(() => r(null), 5000))]);
}

let publicKeyCache: string | null = null;
async function publicKey(): Promise<string> {
  if (publicKeyCache) return publicKeyCache;
  const { data, error } = await supabase.functions.invoke<{ publicKey: string | null }>("push-dispatch", { method: "GET" });
  if (error || !data?.publicKey) throw new Error("推播服務尚未設定，請聯絡系統管理員");
  publicKeyCache = data.publicKey;
  return data.publicKey;
}

function toBytes(b64url: string): Uint8Array {
  const s = atob(b64url.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((b64url.length + 3) % 4));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}
const sameKey = (a: ArrayBuffer | null | undefined, b: Uint8Array) =>
  !!a && a.byteLength === b.length && new Uint8Array(a).every((x, i) => x === b[i]);

async function save(sub: PushSubscription) {
  const json = sub.toJSON();
  await rpc("push_register", { p_endpoint: sub.endpoint, p_p256dh: json.keys?.p256dh, p_auth: json.keys?.auth, p_platform: platform() });
}

/** 伺服器端是否已完成推播設定（Secrets）；未設定時前端不顯示「啟用通知」按鈕 */
export async function pushConfigured(): Promise<boolean> {
  try { await publicKey(); return true; } catch { return false; }
}

/** 使用者按「啟用通知」：要求權限 → 建立（或沿用）瀏覽器訂閱 → 登記到目前帳號 */
export async function enablePush(): Promise<"enabled" | "denied" | "dismissed"> {
  const support = pushSupport();
  if (!support.supported) throw new Error("此瀏覽器無法啟用背景通知");
  const permission = Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
  if (permission === "denied") return "denied";
  if (permission !== "granted") return "dismissed";
  const reg = await registration();
  if (!reg) throw new Error("App 尚未完成安裝，請重新開啟後再試");
  const key = toBytes(await publicKey());
  let sub = await reg.pushManager.getSubscription();
  if (sub && !sameKey(sub.options.applicationServerKey, key)) { await sub.unsubscribe(); sub = null; }
  sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  await save(sub);
  return "enabled";
}

/** 此裝置是否已在目前帳號啟用推播 */
export async function pushEnabledHere(): Promise<boolean> {
  if (!pushSupport().supported || Notification.permission !== "granted") return false;
  const sub = await (await registration())?.pushManager.getSubscription();
  if (!sub) return false;
  const r = await rpc<{ registered: boolean }>("push_status", { p_endpoint: sub.endpoint });
  return r.registered;
}

/** 登入後：此裝置已允許通知且有瀏覽器訂閱時，靜默登記到目前帳號（不詢問權限） */
export async function syncPushAfterLogin(): Promise<void> {
  try {
    if (!pushSupport().supported || Notification.permission !== "granted") return;
    const sub = await (await registration())?.pushManager.getSubscription();
    if (sub) await save(sub);
  } catch { /* 靜默：失敗時使用者可在工作首頁手動啟用 */ }
}

/** 使用者關閉此裝置通知 */
export async function disablePushHere(): Promise<void> {
  const sub = await (await registration())?.pushManager.getSubscription();
  if (!sub) return;
  await rpc("push_unregister", { p_endpoint: sub.endpoint }).catch(() => {});
  await sub.unsubscribe().catch(() => {});
}

/** 登出前：停用此裝置在目前帳號的訂閱（最多等 2 秒，不阻擋登出） */
export async function unregisterPushOnLogout(): Promise<void> {
  const work = (async () => {
    if (!("serviceWorker" in navigator)) return;
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = await reg?.pushManager?.getSubscription();
    if (sub) await rpc("push_unregister", { p_endpoint: sub.endpoint });
  })().catch(() => {});
  await Promise.race([work, new Promise((r) => setTimeout(r, 2000))]);
}

/** 案件操作成功後通知發送端處理佇列（失敗不影響操作；另有排程重試） */
let lastKick = 0;
export function kickPushDispatch() {
  if (Date.now() - lastKick < 2000) return;
  lastKick = Date.now();
  supabase.functions.invoke("push-dispatch", { method: "POST", body: {} }).catch(() => {});
}
