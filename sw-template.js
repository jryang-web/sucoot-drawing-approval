// SUCOOT 圖面申請 service worker（建置時由 vite.config.ts 填入版本與預先快取清單）
// 原則：只快取本站的靜態檔案（畫面），不快取任何 Supabase 資料或登入請求。
const CACHE = "sucoot-__VERSION__";
const PRECACHE = __PRECACHE__;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)));
  // 不自動 skipWaiting：由使用者按「更新」後才切換，避免填寫中的表單被重新整理
});

self.addEventListener("message", (event) => {
  if (event.data === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith("sucoot-") && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

// ---------------------------------------------------------------- V5.9.1 背景推播
// 推播內容只有：角標數字、通知標題／內文（待辦類別與數量）、點擊路由。不含個人或案件資料，也不寫入快取。
// 允許的點擊路由只限 HashRouter 的工作首頁與案件明細；其他一律開啟工作首頁。
const ROUTE = /^#\/(my|r\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;
const safeRoute = (u) => (typeof u === "string" && ROUTE.test(u) ? u : "#/my");
const text = (v, fallback, max) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : fallback);

async function setBadge(n) {
  const nav = self.navigator;
  if (!nav || !("setAppBadge" in nav)) return;
  try { if (n > 0) await nav.setAppBadge(n); else await nav.clearAppBadge(); } catch (e) { /* 未授權或不支援：忽略 */ }
}

self.addEventListener("push", (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = {}; }
  const badge = Number.isInteger(d.badge) && d.badge >= 0 ? Math.min(d.badge, 9999) : null;
  event.waitUntil((async () => {
    if (badge !== null) await setBadge(badge);
    // iPhone／Chrome 要求每則推播都顯示通知；內容無法解析時仍顯示一般提示
    try {
      await self.registration.showNotification(text(d.title, "SUCOOT 圖面申請", 40), {
        body: text(d.body, "您有新的待辦案件", 80),
        icon: "./icons/icon-192.png",
        tag: "sucoot-pending",
        renotify: true,
        data: { url: safeRoute(d.url) },
      });
    } catch (e) { /* 通知權限已被移除：仍通知已開啟的 App 重新同步 */ }
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) c.postMessage({ type: "SUCOOT_BADGE_REFRESH" });
  })());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const hash = safeRoute(event.notification.data && event.notification.data.url);
  const target = new URL("./" + hash, self.registration.scope).href;
  event.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const app = list.find((c) => c.url.startsWith(self.registration.scope));
    if (app) {
      // 已開啟的 App：切換到指定頁面（不重新載入，避免填寫中的表單遺失）；未登入時先顯示登入頁
      app.postMessage({ type: "SUCOOT_NAVIGATE", hash });
      await app.focus();
      return;
    }
    await self.clients.openWindow(target);
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);
  // 只處理本站 GET；Supabase（跨網域）與其他請求一律直接走網路
  if (req.method !== "GET" || url.origin !== self.location.origin) return;

  // 頁面：網路優先（取得最新版），離線時使用快取的畫面
  if (req.mode === "navigate") {
    event.respondWith(fetch(req).catch(async () => (await caches.match("./index.html")) || Response.error()));
    return;
  }
  // 靜態檔（檔名含 hash）：快取優先
  event.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
});
