// V5.9.1：PWA 角標＝目前使用者未讀通知數＋待辦案件數（後端 my_badge_summary 計算，前端不自行推算）
// - 同步時機：登入／開啟、返回前景、恢復連線、完成案件操作、通知標記已讀、切換到工作首頁、收到推播
// - 去重：同一時間只有一個查詢；查詢中又有新的同步需求時，只在結束後再補查一次
// - 換帳號／登出：清除本機角標與計數，並丟棄舊帳號尚未回來的查詢結果
// - 離線：不查詢，畫面標示「離線，數字為最後同步時間的資料」，不把舊數字當成即時資料
import { useSyncExternalStore } from "react";
import { rpc } from "./api";

export type AppBadgeSupport = "supported" | "unsupported" | "failed";
export interface BadgeState {
  owner: string | null;
  total: number | null; unread: number | null; pending: number | null;
  byKind: Record<string, number>;
  syncedAt: string | null;           // 最後成功同步時間（伺服器時間）
  syncing: boolean;
  offline: boolean;
  error: string | null;
  appBadge: AppBadgeSupport;
}
interface Summary { unread_notices: number; pending_cases: number; total: number; by_kind: Record<string, number>; as_of: string }

const appBadgeApi = () => (typeof navigator !== "undefined" && "setAppBadge" in navigator ? navigator : null);
const initial = (): BadgeState => ({
  owner: null, total: null, unread: null, pending: null, byKind: {}, syncedAt: null, syncing: false,
  offline: typeof navigator !== "undefined" && !navigator.onLine, error: null,
  appBadge: appBadgeApi() ? "supported" : "unsupported",
});
let state = initial();
const listeners = new Set<() => void>();
const set = (patch: Partial<BadgeState>) => { state = { ...state, ...patch }; listeners.forEach((l) => l()); };

let inflight: Promise<void> | null = null;
let again = false;
let lastStart = 0;

async function applyAppBadge(total: number) {
  const api = appBadgeApi();
  if (!api) return;
  try {
    if (total > 0) await api.setAppBadge(total); else await api.clearAppBadge();
    if (state.appBadge !== "supported") set({ appBadge: "supported" });
  } catch {
    // 例如 iPhone 尚未允許通知：不影響 App 內計數與其他操作
    set({ appBadge: "failed" });
  }
}

async function clearAppBadge() {
  try { await appBadgeApi()?.clearAppBadge(); } catch { /* 不支援或未授權：忽略 */ }
}

async function load(owner: string) {
  set({ syncing: true });
  try {
    const s = await rpc<Summary>("my_badge_summary");
    if (state.owner !== owner) return;   // 查詢期間已登出或換帳號：丟棄
    set({ total: s.total, unread: s.unread_notices, pending: s.pending_cases, byKind: s.by_kind ?? {},
          syncedAt: s.as_of, error: null, offline: false });
    await applyAppBadge(s.total);
  } catch (e) {
    if (state.owner === owner) set({ error: e instanceof Error ? e.message : String(e), offline: !navigator.onLine });
  } finally {
    if (state.owner === owner) set({ syncing: false });
  }
}

let trailing: number | undefined;

/** 重新取得計數。force=false 時 1.5 秒內的重複觸發會合併為「時間到再查一次」，不會遺漏。 */
export function refreshBadge(force = true): Promise<void> {
  const owner = state.owner;
  if (!owner) return Promise.resolve();
  if (!navigator.onLine) { set({ offline: true }); return Promise.resolve(); }
  if (inflight) { again = true; return inflight; }
  const wait = 1500 - (Date.now() - lastStart);
  if (!force && wait > 0) {
    trailing ??= window.setTimeout(() => { trailing = undefined; void refreshBadge(); }, wait);
    return Promise.resolve();
  }
  if (trailing !== undefined) { window.clearTimeout(trailing); trailing = undefined; }
  lastStart = Date.now();
  inflight = load(owner).finally(() => {
    inflight = null;
    if (again && state.owner === owner) { again = false; void refreshBadge(); }
  });
  return inflight;
}

/** 登入（或開啟 App）後開始同步此員工的計數；換帳號時先清除舊資料 */
export function startBadge(employeeId: string) {
  if (state.owner !== employeeId) {
    state = { ...initial(), owner: employeeId };
    void clearAppBadge();
    listeners.forEach((l) => l());
  }
  return refreshBadge();
}

/** 登出、帳號停用、工作階段失效：清除本機角標與計數 */
export function stopBadge() {
  state = initial();
  again = false;
  if (trailing !== undefined) { window.clearTimeout(trailing); trailing = undefined; }
  listeners.forEach((l) => l());
  return clearAppBadge();
}

export const badgeRefreshEvent = "sucoot-badge-refresh";
export function requestBadgeRefresh() { window.dispatchEvent(new Event(badgeRefreshEvent)); }

export function useBadge(): BadgeState {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l); }, () => state, () => state);
}

// 測試用：取得目前狀態（不影響行為）
export const badgeSnapshot = () => state;
