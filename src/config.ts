// 開發環境預設值：sucoot-drawing-dev（publishable key 可公開；權限由 RLS 與 RPC 控管）
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://qifjiaxskortyennnpsh.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_pWMuXx7uLzKnhTlfjoL52Q_SrCOJ5aC";
export const LOGIN_EMAIL_DOMAIN = "login.sucoot.com";

// 環境標示：正式上線時改為空字串
export const APP_NAME = "SUCOOT 圖面申請";
export const APP_STAGE = "測試版";
export const APP_VERSION = __APP_VERSION__;
export const BUILD_SHA = __BUILD_SHA__;
export const BUILD_TIME = __BUILD_TIME__;
