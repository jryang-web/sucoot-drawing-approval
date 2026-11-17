// SUCOOT 圖面申請 service worker（建置時由 vite.config.ts 填入版本與預先快取清單）
// 原則：只快取本站的靜態檔案（畫面），不快取任何 Supabase 資料或登入請求。
const CACHE = "sucoot-0.1.3-6db518e-1794915233500";
const PRECACHE = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./assets/index-BJ-q5wiS.css",
  "./assets/index-DKG9qK9Z.js",
  "./assets/browser-ImKn0pwh.js",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png"
];

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
