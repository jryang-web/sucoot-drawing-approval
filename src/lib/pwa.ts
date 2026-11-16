// PWA：service worker 註冊、新版本偵測、安裝提示、離線狀態
import { useSyncExternalStore } from "react";

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

interface PwaState {
  updateReady: boolean;
  canInstall: boolean;
  online: boolean;
}

let state: PwaState = { updateReady: false, canInstall: false, online: typeof navigator === "undefined" ? true : navigator.onLine };
let waiting: ServiceWorker | null = null;
let installEvent: BeforeInstallPromptEvent | null = null;
let updating = false; // 只有使用者按「立即更新」後才重新整理（首次安裝接管頁面時不重新整理）
const listeners = new Set<() => void>();
const set = (patch: Partial<PwaState>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()); };

export const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;
export const isIOS = /iPhone|iPad|iPod/i.test(ua) || (/Macintosh/.test(ua) && typeof document !== "undefined" && "ontouchend" in document);
export const isLineApp = /\bLine\//i.test(ua);
export const isStandalone = () =>
  typeof window !== "undefined" &&
  (window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true);

export function initPwa() {
  window.addEventListener("online", () => set({ online: true }));
  window.addEventListener("offline", () => set({ online: false }));
  window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    installEvent = e as BeforeInstallPromptEvent;
    set({ canInstall: true });
  });
  window.addEventListener("appinstalled", () => { installEvent = null; set({ canInstall: false }); });

  // 開發模式不註冊，避免快取干擾
  if (!import.meta.env.PROD || !("serviceWorker" in navigator)) return;
  window.addEventListener("load", async () => {
    try {
      const reg = await navigator.serviceWorker.register("./sw.js", { scope: "./" });
      const track = (sw: ServiceWorker | null) => {
        if (!sw) return;
        const check = () => {
          // 已有舊版在控制頁面時，新版安裝完成 = 有更新可用
          if (sw.state === "installed" && navigator.serviceWorker.controller) { waiting = sw; set({ updateReady: true }); }
        };
        check();
        sw.addEventListener("statechange", check);
      };
      track(reg.waiting);
      reg.addEventListener("updatefound", () => track(reg.installing));
      // 定期檢查新版（App 長時間開著時）
      setInterval(() => reg.update().catch(() => {}), 30 * 60 * 1000);
      document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") reg.update().catch(() => {}); });
    } catch (e) {
      console.warn("service worker 註冊失敗", e);
    }
  });
  navigator.serviceWorker?.addEventListener("controllerchange", () => {
    if (!updating) return;
    updating = false;
    window.location.reload();
  });
}

export function applyUpdate() {
  if (!waiting) return;
  updating = true;
  waiting.postMessage("SKIP_WAITING");
}

export async function promptInstall() {
  if (!installEvent) return;
  await installEvent.prompt();
  await installEvent.userChoice;
  installEvent = null;
  set({ canInstall: false });
}

export function usePwa(): PwaState {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l); }, () => state, () => state);
}
