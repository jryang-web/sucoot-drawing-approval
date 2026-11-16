import { createClient } from "@supabase/supabase-js";
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL, LOGIN_EMAIL_DOMAIN } from "../config";

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
});

export const emailOf = (employeeNo: string) => `${employeeNo.trim().toLowerCase()}@${LOGIN_EMAIL_DOMAIN}`;
