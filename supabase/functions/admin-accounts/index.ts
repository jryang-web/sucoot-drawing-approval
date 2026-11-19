// SUCOOT V5.7 | admin-accounts
// 帳號管理（需要 Auth Admin 權限的操作）。service_role key 由 Supabase 平台注入，不會出現在前端或程式碼中。
// 每個請求都以呼叫者的 JWT 驗證身分；管理操作再由資料庫 svc_* 函式確認呼叫者為啟用中的 SYS_ADMIN。
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const EMAIL_DOMAIN = "login.sucoot.com";
const MIN_PASSWORD = 12;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

class HttpError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function emailOf(employeeNo: string) {
  return `${employeeNo.trim().toLowerCase()}@${EMAIL_DOMAIN}`;
}

// 16 碼，保證含大小寫、數字、符號；排除易混淆字元
function generatePassword(length = 16): string {
  const sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "!@#$%^&*-_=+?"];
  const all = sets.join("");
  const pick = (s: string) => {
    const b = new Uint32Array(1);
    crypto.getRandomValues(b);
    return s[b[0] % s.length];
  };
  const chars = sets.map(pick);
  while (chars.length < length) chars.push(pick(all));
  for (let i = chars.length - 1; i > 0; i--) {
    const b = new Uint32Array(1);
    crypto.getRandomValues(b);
    const j = b[0] % (i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join("");
}

function checkPassword(pw: unknown): string {
  if (typeof pw !== "string" || pw.length < MIN_PASSWORD) {
    throw new HttpError(400, "WEAK_PASSWORD", `密碼至少 ${MIN_PASSWORD} 碼`);
  }
  const classes = [/[A-Z]/, /[a-z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((r) => r.test(pw)).length;
  if (classes < 3) throw new HttpError(400, "WEAK_PASSWORD", "密碼需包含大寫、小寫、數字、符號其中至少三類");
  return pw;
}

// 資料庫錯誤格式為 "CODE: 訊息"
async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) {
    const m = /^([A-Z_]+): (.*)$/s.exec(error.message);
    const code = m?.[1] ?? "DB_ERROR";
    const status = code === "FORBIDDEN" || code === "PASSWORD_CHANGE_REQUIRED" ? 403 : 400;
    throw new HttpError(status, code, m?.[2] ?? "資料庫錯誤");
  }
  return data as T;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { code: "METHOD_NOT_ALLOWED", message: "僅接受 POST" });

  try {
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!token) throw new HttpError(401, "UNAUTHENTICATED", "尚未登入");
    const { data: userData, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !userData?.user) throw new HttpError(401, "UNAUTHENTICATED", "登入已失效，請重新登入");
    const caller = userData.user;

    const body = await req.json().catch(() => ({}));
    const action = body?.action;

    switch (action) {
      // 員工本人修改密碼（首次登入強制修改）
      case "change_own_password": {
        const newPw = checkPassword(body.new_password);
        if (typeof body.current_password !== "string") throw new HttpError(400, "INVALID_INPUT", "請輸入目前密碼");
        if (body.current_password === newPw) throw new HttpError(400, "WEAK_PASSWORD", "新密碼不可與目前密碼相同");
        const verifier = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
        const { error: signErr } = await verifier.auth.signInWithPassword({ email: caller.email!, password: body.current_password });
        if (signErr) throw new HttpError(400, "WRONG_PASSWORD", "目前密碼不正確");
        await verifier.auth.signOut({ scope: "local" }).catch(() => {}); // 只結束驗證用的 session
        const { error } = await admin.auth.admin.updateUserById(caller.id, { password: newPw });
        if (error) throw new HttpError(400, "AUTH_ERROR", error.message);
        await rpc("svc_password_changed", { p_auth_user_id: caller.id });
        return json(200, { ok: true });
      }

      // 管理者建立帳號：Auth 帳號 + 員工資料 + 角色 + 管轄；失敗時刪除剛建立的 Auth 帳號
      case "create_account": {
        const employeeNo = String(body.employee_no ?? "").trim();
        const name = String(body.name ?? "").trim();
        if (!name) throw new HttpError(400, "INVALID_INPUT", "請輸入姓名");
        await rpc("svc_check_new_employee", {
          p_caller_auth: caller.id, p_employee_no: employeeNo, p_department_id: body.department_id ?? null,
        });
        const password = generatePassword();
        const { data: created, error } = await admin.auth.admin.createUser({
          email: emailOf(employeeNo), password, email_confirm: true,
          app_metadata: { employee_no: employeeNo },
        });
        if (error || !created?.user) {
          throw new HttpError(400, "AUTH_ERROR", error?.message?.includes("already") ? "此員工編號的登入帳號已存在" : (error?.message ?? "建立帳號失敗"));
        }
        try {
          const employeeId = await rpc<string>("svc_create_employee", {
            p_caller_auth: caller.id, p_auth_user_id: created.user.id, p_employee_no: employeeNo, p_name: name,
            p_department_id: body.department_id, p_roles: Array.isArray(body.roles) ? body.roles : [],
            p_manager_department_ids: Array.isArray(body.manager_department_ids) ? body.manager_department_ids : [],
            p_reason: body.reason ?? null,
          });
          // 初始密碼只回傳這一次，系統不保存
          return json(200, { ok: true, employee_id: employeeId, employee_no: employeeNo, initial_password: password });
        } catch (e) {
          await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
          throw e;
        }
      }

      // 管理者重設密碼：產生新密碼，並要求下次登入修改
      case "reset_password": {
        const authId = await rpc<string>("svc_get_employee_auth", { p_caller_auth: caller.id, p_employee_id: body.employee_id });
        if (authId === caller.id) throw new HttpError(403, "FORBIDDEN", "不可透過管理後台重設自己的密碼");
        const password = generatePassword();
        const { error } = await admin.auth.admin.updateUserById(authId, { password });
        if (error) throw new HttpError(400, "AUTH_ERROR", error.message);
        await rpc("svc_after_password_reset", { p_caller_auth: caller.id, p_employee_id: body.employee_id, p_reason: body.reason ?? null });
        return json(200, { ok: true, new_password: password });
      }

      // 管理者啟用／停用：業務權限立即失效，並封鎖 Auth 帳號（無法再取得新 token）
      case "set_active": {
        const active = body.active === true;
        const authId = await rpc<string | null>("svc_set_active", {
          p_caller_auth: caller.id, p_employee_id: body.employee_id, p_active: active, p_reason: body.reason ?? null,
        });
        if (authId) {
          const { error } = await admin.auth.admin.updateUserById(authId, { ban_duration: active ? "none" : "876000h" });
          if (error) throw new HttpError(500, "AUTH_ERROR", `業務權限已${active ? "啟用" : "停用"}，但登入封鎖設定失敗：${error.message}`);
        }
        return json(200, { ok: true });
      }

      default:
        throw new HttpError(400, "UNKNOWN_ACTION", "未知的操作");
    }
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { code: e.code, message: e.message });
    console.error(e);
    return json(500, { code: "INTERNAL", message: "系統錯誤" });
  }
});
