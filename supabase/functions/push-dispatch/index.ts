// SUCOOT V5.9.1 | push-dispatch
// 發送推播佇列。呼叫方式：
//   1. 員工完成案件操作後由前端觸發（帶員工 JWT；先確認為有效員工，才處理佇列）
//   2. 排程重試（pg_cron＋pg_net，帶 x-push-cron-secret）
//   GET：回傳 VAPID 公鑰（公開值，供前端建立訂閱）
// 秘密（VAPID_PRIVATE_KEY、PUSH_CRON_SECRET、service_role key）只存在 Supabase Secrets，不會回傳或寫入日誌。
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { dispatch, type Batch, type Store } from "./dispatch.ts";
import { checkVapidKeys } from "./webpush.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
// Secrets 去除前後空白與換行（從檔案或編輯器複製貼上時常夾帶換行）
const secret = (name: string) => (Deno.env.get(name) ?? "").trim();
const VAPID_PUBLIC_KEY = secret("VAPID_PUBLIC_KEY");
const VAPID_PRIVATE_KEY = secret("VAPID_PRIVATE_KEY");
const VAPID_SUBJECT = secret("VAPID_SUBJECT");
const CRON_SECRET = secret("PUSH_CRON_SECRET");

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

// 設定檢查只做一次（Secrets 變更後函式會重新啟動）；只回傳狀態代碼（名稱與檢查結果），不輸出任何值
let configError: Promise<string | null> | null = null;
const vapidConfigError = () => (configError ??= (async () => {
  const missing = Object.entries({ VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT }).filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) return "MISSING:" + missing.join(",");
  return await checkVapidKeys({ publicKey: VAPID_PUBLIC_KEY, privateKey: VAPID_PRIVATE_KEY, subject: VAPID_SUBJECT });
})());

function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function cronOkInVault(value: string): Promise<boolean> {
  const { data, error } = await admin.rpc("svc_push_cron_ok", { p_secret: value });
  return !error && data === true;
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
  if (req.method === "GET") {
    // status：OK／MISSING:<名稱>／VAPID_SUBJECT_INVALID／VAPID_KEY_MISMATCH／VAPID_*_INVALID（供維護人員檢查，不含任何值）
    const bad = await vapidConfigError();
    return json(200, { publicKey: bad ? null : VAPID_PUBLIC_KEY, status: bad ?? "OK", cron: CRON_SECRET.length >= 32 ? "SET" : "NOT_SET" });
  }
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  // 排程呼叫：比對 Edge Function Secret（PUSH_CRON_SECRET）或 Vault 中的 sucoot_push_cron_secret（資料庫內比對，不取出值）
  const cronHeader = req.headers.get("x-push-cron-secret") ?? "";
  const cron = sameSecret(cronHeader, CRON_SECRET) || (cronHeader.length >= 32 && await cronOkInVault(cronHeader));
  if (!cron && !(await isEmployee(req))) return json(401, { error: "UNAUTHORIZED" });
  // 未設定、金鑰不配對或 sub 格式錯誤時不取出佇列（避免整批失敗），由管理員修正 Secrets
  const bad = await vapidConfigError();
  if (bad) { console.error("push-dispatch config", bad); return json(503, { error: bad.startsWith("MISSING:") ? "PUSH_NOT_CONFIGURED" : bad }); }

  try {
    const summary = await dispatch(store, { publicKey: VAPID_PUBLIC_KEY, privateKey: VAPID_PRIVATE_KEY, subject: VAPID_SUBJECT });
    console.log("push-dispatch", JSON.stringify({ source: cron ? "cron" : "client", ...summary }));
    return json(200, summary);
  } catch (e) {
    console.error("push-dispatch failed", (e as Error).message);
    return json(500, { error: "DISPATCH_FAILED" });
  }
});
