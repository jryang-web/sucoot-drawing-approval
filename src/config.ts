// 開發環境預設值：sucoot-drawing-dev（publishable key 可公開；權限由 RLS 與 RPC 控管）
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL ?? "https://qifjiaxskortyennnpsh.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? "sb_publishable_pWMuXx7uLzKnhTlfjoL52Q_SrCOJ5aC";
export const LOGIN_EMAIL_DOMAIN = "login.sucoot.com";
