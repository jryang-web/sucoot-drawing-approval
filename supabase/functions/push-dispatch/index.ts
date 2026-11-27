// SUCOOT V5.9.1 | push-dispatch
// 發送推播佇列。呼叫方式：
//   1. 員工完成案件操作後由前端觸發（帶員工 JWT；先確認為有效員工，才處理佇列）
//   2. 排程重試（pg_cron＋pg_net，帶 x-push-cron-secret）
//   GET：回傳 VAPID 公鑰（公開值，供前端建立訂閱）
// 秘密（VAPID_PRIVATE_KEY、PUSH_CRON_SECRET、service_role key）只存在 Supabase Secrets，不會回傳或寫入日誌。
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { dispatch, type Batch, type Store } from "./dispatch.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "";
const CRON_SECRET = Deno.env.get("PUSH_CRON_SECRET") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const store: Store = {
  async claim(limit) {
    const { data, error } = await admin.rpc("svc_push_claim", { p_limit: limit });
    if (error) throw new Error("CLAIM_FAILED");
    return (data ?? []) as Batch[];
  },
  async report(ids, results) {
    const { error } = await admin.rpc("svc_push_report", { p_outbox_ids: ids, p_results: results });
    if (error) throw new Error("REPORT_FAILED");
  },
};

function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// 員工呼叫：以呼叫者 JWT 呼叫 me()，確認為啟用中且工作階段有效的員工
async function isEmployee(req: Request): Promise<boolean> {
  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return false;
  const user = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: authorization } },
  });
  const { data, error } = await user.rpc("me");
  return !error && !!data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const configured = !!(VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY && VAPID_SUBJECT);
  if (req.method === "GET") return json(200, { publicKey: configured ? VAPID_PUBLIC_KEY : null });
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  const cron = sameSecret(req.headers.get("x-push-cron-secret") ?? "", CRON_SECRET);
  if (!cron && !(await isEmployee(req))) return json(401, { error: "UNAUTHORIZED" });
  if (!configured) return json(503, { error: "PUSH_NOT_CONFIGURED" });

  try {
    const summary = await dispatch(store, { publicKey: VAPID_PUBLIC_KEY, privateKey: VAPID_PRIVATE_KEY, subject: VAPID_SUBJECT });
    console.log("push-dispatch", JSON.stringify({ source: cron ? "cron" : "client", ...summary }));
    return json(200, summary);
  } catch (e) {
    console.error("push-dispatch failed", (e as Error).message);
    return json(500, { error: "DISPATCH_FAILED" });
  }
});
