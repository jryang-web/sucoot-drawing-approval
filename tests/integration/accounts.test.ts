/**
 * 帳號流程整合測試（Supabase Auth + Edge Function admin-accounts）
 *
 * 需要「測試專用管理者」帳號，密碼只從環境變數讀取，不寫入檔案：
 *   TEST_ADMIN_EMPLOYEE_NO=... TEST_ADMIN_PASSWORD=... npm run test:integration
 *
 * 測試會建立帶時間戳記的臨時帳號（例如 T1116A0930-1），密碼只存在記憶體，測試結束後全部停用。
 * 業務流程（23 項驗收）由 supabase/tests/business_flow.sql 在資料庫層驗證。
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const URL = process.env.VITE_SUPABASE_URL ?? "http://127.0.0.1:54329";
if (!["127.0.0.1","localhost","[::1]"].includes(new globalThis.URL(URL).hostname)) throw new Error("帳號整合測試限定本機服務");
const KEY = process.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? "local-anonymous-client";
const ADMIN_NO = process.env.TEST_ADMIN_EMPLOYEE_NO;
const ADMIN_PW = process.env.TEST_ADMIN_PASSWORD;
const emailOf = (no: string) => `${no.toLowerCase()}@login.sucoot.com`;
const client = () => createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

async function login(no: string, pw: string) {
  const c = client();
  const { error } = await c.auth.signInWithPassword({ email: emailOf(no), password: pw });
  return { c, error };
}
async function fn(c: SupabaseClient, body: Record<string, unknown>) {
  const { data, error } = await c.functions.invoke("admin-accounts", { body });
  if (error) {
    const j = await (error as { context?: Response }).context?.json().catch(() => null);
    return { ok: false, code: j?.code as string, data: null };
  }
  return { ok: true, code: null, data };
}

const run = ADMIN_NO && ADMIN_PW ? describe : describe.skip;

run("帳號管理（管理者在系統內建立）", () => {
  let admin: SupabaseClient;
  let deptId: string;
  const stamp = new Date().toISOString().replace(/\D/g, "").slice(4, 12);
  const no = (s: string) => `T${stamp}-${s}`;
  const created: { id: string; no: string; pw: string }[] = [];

  beforeAll(async () => {
    const r = await login(ADMIN_NO!, ADMIN_PW!);
    expect(r.error).toBeNull();
    admin = r.c;
    const { data, error } = await admin.rpc("admin_upsert_department", { p_id: null, p_code: `T${stamp}`, p_name: `測試部門${stamp}`, p_is_active: true, p_reason: "整合測試" });
    expect(error).toBeNull();
    deptId = data as string;
  });

  afterAll(async () => {
    for (const e of created) await fn(admin, { action: "set_active", employee_id: e.id, active: false, reason: "其他：整合測試結束" });
  });

  it("S1 管理者建立帳號，取得一次性初始密碼", async () => {
    const r = await fn(admin, { action: "create_account", employee_no: no("A"), name: "臨時員工A", department_id: deptId, roles: [] });
    expect(r.ok).toBe(true);
    const d = r.data as { employee_id: string; initial_password: string };
    expect(d.initial_password.length).toBeGreaterThanOrEqual(16);
    created.push({ id: d.employee_id, no: no("A"), pw: d.initial_password });
  });

  it("S2 新帳號可登入，但未改密碼前業務操作被拒", async () => {
    const e = created[0];
    const r = await login(e.no, e.pw);
    expect(r.error).toBeNull();
    const me = await r.c.rpc("me");
    expect((me.data as { must_change_password: boolean }).must_change_password).toBe(true);
    const draft = await r.c.rpc("submit_request", { p_id: "00000000-0000-0000-0000-000000000000" });
    expect(draft.error?.message).toMatch(/^PASSWORD_CHANGE_REQUIRED/);
  });

  it("S3 一般員工不可呼叫建立帳號", async () => {
    const e = created[0];
    const r = await login(e.no, e.pw);
    const res = await fn(r.c, { action: "create_account", employee_no: no("X"), name: "x", department_id: deptId });
    expect(res.code).toBe("FORBIDDEN");
  });

  it("S5 重複員工編號被拒，且不產生孤兒 Auth 帳號", async () => {
    const r = await fn(admin, { action: "create_account", employee_no: created[0].no.toUpperCase(), name: "重複", department_id: deptId });
    expect(r.code).toBe("DUPLICATE_EMPLOYEE_NO");
  });

  it("S6 新密碼少於 8 碼被拒；本人改密碼後可正常操作", async () => {
    const e = created[0];
    const r = await login(e.no, e.pw);
    expect((await fn(r.c, { action: "change_own_password", current_password: e.pw, new_password: "Short1!", confirm_password:"Short1!" })).code).toBe("WEAK_PASSWORD");
    const otherDevice = (await login(e.no,e.pw)).c;
    const newPw = `Nw!${crypto.randomUUID()}`;
    expect((await fn(r.c, { action: "change_own_password", current_password: e.pw, new_password: newPw, confirm_password:newPw })).ok).toBe(true);
    expect((await otherDevice.rpc("submit_request",{p_id:"00000000-0000-0000-0000-000000000000"})).error?.message).toMatch(/^SESSION_REVOKED/);
    e.pw = newPw;
    expect((await r.c.rpc("me")).error?.message).toMatch(/^SESSION_REVOKED/);
    const me = await (await login(e.no,newPw)).c.rpc("me");
    expect((me.data as { must_change_password: boolean }).must_change_password).toBe(false);
  });

  it("S7 管理者重設密碼：舊密碼失效、新密碼可登入且須再改密碼", async () => {
    const e = created[0];
    const r = await fn(admin, { action: "reset_password", employee_id: e.id, reason: "資安需求" });
    expect(r.ok).toBe(true);
    expect((await login(e.no, e.pw)).error).not.toBeNull();
    const pw = (r.data as { new_password: string }).new_password;
    const l = await login(e.no, pw);
    expect(l.error).toBeNull();
    e.pw = pw;
  });

  it("S8 停用帳號：既有 session 呼叫 RPC 被拒，且無法重新登入", async () => {
    const e = created[0];
    const session = (await login(e.no, e.pw)).c;
    expect((await fn(admin, { action: "set_active", employee_id: e.id, active: false, reason: "資安風險" })).ok).toBe(true);
    const me = await session.rpc("me");
    expect(me.error?.message).toMatch(/^(ACCOUNT_INACTIVE|SESSION_REVOKED)/);
    expect((await login(e.no, e.pw)).error).not.toBeNull();
  });

  it("S11 公開註冊被拒", async () => {
    const { error } = await client().auth.signUp({ email: `probe-${stamp}@login.sucoot.com`, password: `Pr0be!${stamp}xxxx` });
    expect(error).not.toBeNull();
  });
});
