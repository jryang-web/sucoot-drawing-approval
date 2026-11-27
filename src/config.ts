const pages = __PAGES_CONNECTION__;
if (!pages && !["localhost", "127.0.0.1", "[::1]"].includes(window.location.hostname))
  throw new Error("本機建置僅供本機使用；GitHub Pages 請使用 pages 模式建置");
export const SUPABASE_URL = pages?.url ?? window.location.origin;
export const SUPABASE_PUBLISHABLE_KEY = pages?.key ?? "local-anonymous-client";
export const LOGIN_EMAIL_DOMAIN = "login.sucoot.com";

export const APP_NAME = "SUCOOT 圖面申請";
// 對外顯示的產品版本（V5.x）；與 package.json 的程式版本（APP_VERSION）用途不同，不互相取代
export const PRODUCT_VERSION = "V5.9.2";
// 環境標示：目前為試用階段，本機與 GitHub Pages 正式網站都顯示「測試版」；正式上線時改為空字串
export const APP_STAGE = "測試版";
export const RELEASE_LABEL = APP_STAGE ? `${PRODUCT_VERSION} ${APP_STAGE}` : PRODUCT_VERSION;
export const APP_VERSION = __APP_VERSION__;
export const BUILD_SHA = __BUILD_SHA__;
export const BUILD_TIME = __BUILD_TIME__;
