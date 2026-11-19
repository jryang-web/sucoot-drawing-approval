const pages = __PAGES_CONNECTION__;
if (!pages && !["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname))
  throw new Error("本機建置僅供本機使用；GitHub Pages 請使用 pages 模式建置");
export const SUPABASE_URL = pages?.url ?? window.location.origin;
export const SUPABASE_PUBLISHABLE_KEY = pages?.key ?? "local-anonymous-client";
export const LOGIN_EMAIL_DOMAIN = "login.sucoot.com";

// 環境標示：正式上線時改為空字串
export const APP_NAME = "SUCOOT 圖面申請";
export const APP_STAGE = pages ? "" : "測試版";
export const APP_VERSION = __APP_VERSION__;
export const BUILD_SHA = __BUILD_SHA__;
export const BUILD_TIME = __BUILD_TIME__;
