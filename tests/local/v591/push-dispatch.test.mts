// SUCOOT V5.9.1｜推播發送端隔離測試
// - 資料庫：本機隔離 PostgreSQL（tests/local/v59/setup.sh 建立），不連線正式 Supabase
// - 推播服務：本機假推播服務（127.0.0.1），以獨立實作 http_ece 解密內容、以 Node crypto 驗證 VAPID 簽章
// - VAPID 金鑰與裝置金鑰皆於執行時隨機產生，不寫入任何檔案
// 執行：node tests/local/v591/push-dispatch.test.mts
import http from "node:http";
import crypto from "node:crypto";
import pg from "pg";
import ece from "http_ece";
import { dispatch, type Store, type Batch } from "../../../supabase/functions/push-dispatch/dispatch.ts";
import { b64urlEncode, endpointAllowed } from "../../../supabase/functions/push-dispatch/webpush.ts";

const pool = new pg.Pool({ host: "/var/lib/postgresql/sucoot-v59/run", port: 54330, user: "postgres", database: "postgres" });
const results: { name: string; ok: boolean; detail?: string }[] = [];
const check = (name: string, ok: boolean, detail = "") => {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok || !detail ? "" : " — " + detail}`);
};

// ---------- 測試用金鑰（執行時產生）
const vapid = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
const vapidJwk = vapid.privateKey.export({ format: "jwk" });
const vapidPublic = b64urlEncode(new Uint8Array(Buffer.concat([Buffer.from([4]),
  Buffer.from(vapidJwk.x!, "base64url"), Buffer.from(vapidJwk.y!, "base64url")])));
const keys = { publicKey: vapidPublic, privateKey: vapidJwk.d!, subject: "https://example.invalid/sucoot-test" };

function device() {
  const ecdh = crypto.createECDH("prime256v1");
  ecdh.generateKeys();
  return { ecdh, p256dh: ecdh.getPublicKey().toString("base64url"), auth: crypto.randomBytes(16).toString("base64url") };
}
const dev1 = device(), dev2 = device(), dev3 = device();

// ---------- 假推播服務
const received: { path: string; payload: any; jwt: any; headers: http.IncomingHttpHeaders }[] = [];
let mode: Record<string, number> = {};
const server = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const path = req.url!;
    const forced = Object.entries(mode).find(([p]) => path.startsWith(p))?.[1];
    if (forced) { res.writeHead(forced); return res.end(); }
    try {
      // VAPID：Authorization: vapid t=<jwt>, k=<公鑰>
      const m = /^vapid t=([^,]+), k=(.+)$/.exec(req.headers.authorization ?? "");
      if (!m || m[2] !== vapidPublic) throw new Error("bad vapid header");
      const [h, b, s] = m[1].split(".");
      const pub = crypto.createPublicKey({ key: { kty: "EC", crv: "P-256", x: vapidJwk.x, y: vapidJwk.y }, format: "jwk" });
      if (!crypto.verify("sha256", Buffer.from(`${h}.${b}`), { key: pub, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url")))
        throw new Error("bad vapid signature");
      const claims = JSON.parse(Buffer.from(b, "base64url").toString());
      if (claims.aud !== `http://${req.headers.host}` || claims.exp < Date.now() / 1000) throw new Error("bad vapid claims");
      if (req.headers["content-encoding"] !== "aes128gcm") throw new Error("bad encoding");
      const dev = path.includes("dev1") ? dev1 : path.includes("dev2") ? dev2 : dev3;
      const plain = ece.decrypt(Buffer.concat(chunks), { version: "aes128gcm", privateKey: dev.ecdh, authSecret: dev.auth });
      received.push({ path, payload: JSON.parse(plain.toString()), jwt: claims, headers: req.headers });
      res.writeHead(201); res.end();
    } catch (e) {
      received.push({ path, payload: null, jwt: null, headers: req.headers });
      res.writeHead(400); res.end(String((e as Error).message));
    }
  });
});
await new Promise<void>((r) => server.listen(54340, "127.0.0.1", r));
const BASE = "http://127.0.0.1:54340";
const extraHosts = ["127.0.0.1:54340", "127.0.0.1:54341"];   // 僅測試允許的本機假推播服務

// ---------- 資料庫存取（與 Edge Function 相同，以 service_role 呼叫 svc_push_*）
async function asService<T>(sql: string, params: unknown[]): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query("begin"); await c.query("set local role service_role");
    const r = await c.query(sql, params); await c.query("commit");
    return r.rows[0]?.r as T;
  } catch (e) { await c.query("rollback"); throw e; } finally { c.release(); }
}
const store: Store = {
  claim: (n) => asService<Batch[]>("select public.svc_push_claim($1) as r", [n]),
  report: (ids, res) => asService("select public.svc_push_report($1::bigint[], $2::jsonb) as r", [ids, JSON.stringify(res)]),
};
async function asEmployee(no: string, sql: string, params: unknown[] = []) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query(`select set_config('request.jwt.claims', jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text, true)
                     from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
                    where e.employee_no = $1`, [no]);
    await c.query("set local role authenticated");
    const r = await c.query(sql, params); await c.query("commit");
    return r.rows[0]?.r;
  } catch (e) { await c.query("rollback"); throw e; } finally { c.release(); }
}
async function submit(no: string): Promise<string> {
  const key = crypto.randomUUID();
  await asEmployee(no, "select public.prepare_operation($1, 'write_r8_application', $2::jsonb) as r", [key, JSON.stringify({
    p_purpose: "推播測試", p_urgent: false, p_reason: null, p_note: null, p_submit: true, p_id: null, p_version: null,
    p_products: [{ code: "PUSH-" + key.slice(0, 6), name: "推播測試" }] })]);
  const out = await asEmployee(no, "select public.execute_operation($1) as r", [key]);
  if (!out.ok) throw new Error("submit failed " + JSON.stringify(out));
  return out.id;
}
const q = async (sql: string, p: unknown[] = []) => (await pool.query(sql, p)).rows;

try {
  // 先清空舊佇列（隔離資料庫）並以測試裝置登記 TEST003 的訂閱（假推播服務位址不在正式允許清單，故以資料庫直接寫入）
  await q("update app.push_outbox set status = 'SENT', locked_until = null where status in ('PENDING','SENDING')");
  await q("update app.push_subscriptions set revoked_at = now(), revoke_reason = 'TEST_RESET' where revoked_at is null");
  const sess = (await q(`select e.id emp, (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) sid
                           from public.employees e where employee_no = 'TEST003'`))[0];
  for (const [path, d] of [["/ok/dev1", dev1], ["/gone/dev2", dev2]] as const) {
    await q(`insert into app.push_subscriptions (employee_id, session_id, endpoint, p256dh, auth) values ($1, $2, $3, $4, $5)
             on conflict (endpoint) do update set revoked_at = null, employee_id = excluded.employee_id, session_id = excluded.session_id,
               p256dh = excluded.p256dh, auth = excluded.auth`, [sess.emp, sess.sid, BASE + path, d.p256dh, d.auth]);
  }
  mode = { "/gone/": 410 };

  // ---------- 1. 送件 → 第一層主管收到推播
  const req1 = await submit("TEST001");
  const sum1 = await dispatch(store, keys, { extraHosts });
  const got = received.filter((r) => r.path === "/ok/dev1");
  const badge = (await q("select (app.badge_counts(id)->>'total')::int n from public.employees where employee_no = 'TEST003'"))[0].n;
  check("W1 推播服務收到內容，VAPID 簽章（ES256）驗證通過", got.length === 1 && got[0].jwt?.sub === keys.subject);
  check("W2 內容以 aes128gcm 加密，獨立實作 http_ece 可正確解密", got[0]?.payload?.v === 1);
  check("W3 角標數字＝該主管即時未讀＋待辦總數", got[0]?.payload?.badge === badge, `${got[0]?.payload?.badge} vs ${badge}`);
  check("W4 通知點擊網址為 HashRouter 案件路由", got[0]?.payload?.url === `#/r/${req1}`);
  const reqNo = (await q("select request_no from public.drawing_requests where id = $1", [req1]))[0].request_no;
  check("W5 通知內容不含案件編號、申請人姓名或產品資料",
    !JSON.stringify(got[0]?.payload).includes(reqNo) && !JSON.stringify(got[0]?.payload).includes("測試員工")
    && !JSON.stringify(got[0]?.payload).includes("PUSH-"), JSON.stringify(got[0]?.payload));
  check("W6 TTL、Urgency、Topic 標頭正確", got[0]?.headers.ttl === "86400" && got[0]?.headers.urgency === "high" && got[0]?.headers.topic === "sucoot-pending");
  check("W7 發送摘要只有數量（無 endpoint）", !JSON.stringify(sum1).includes("127.0.0.1") && sum1.accepted === 1, JSON.stringify(sum1));
  const s2 = (await q("select revoke_reason from app.push_subscriptions where endpoint = $1", [BASE + "/gone/dev2"]))[0];
  check("T19 推播服務回 410 → 該裝置訂閱自動停用", s2.revoke_reason === "EXPIRED");
  const ob1 = await q("select status, accepted_count from app.push_outbox where request_id = $1", [req1]);
  check("D6 佇列狀態為 SENT（推播服務已接受；不代表裝置已收到）", ob1.length === 1 && ob1[0].status === "SENT" && ob1[0].accepted_count === 1);

  // ---------- 2. 暫時性失敗（500）→ 重試 → 成功
  mode = { "/ok/": 500 };
  const req2 = await submit("TEST002");
  await dispatch(store, keys, { extraHosts });
  const ob2 = (await q("select status, attempts, next_attempt_at > now() later from app.push_outbox where request_id = $1", [req2]))[0];
  check("R1 推播服務 500 → 佇列保留並排程重試", ob2.status === "PENDING" && ob2.attempts === 1 && ob2.later);
  mode = {};
  await q("update app.push_outbox set next_attempt_at = now() where request_id = $1", [req2]);
  const before = received.length;
  await dispatch(store, keys, { extraHosts });
  const ob2b = (await q("select status, attempts from app.push_outbox where request_id = $1", [req2]))[0];
  check("R2 重試成功 → SENT，且只送出一次", ob2b.status === "SENT" && ob2b.attempts === 2 && received.length === before + 1);

  // ---------- 3. 網路錯誤（無服務的連接埠）
  await q("update app.push_subscriptions set endpoint = $1 where endpoint = $2", ["http://127.0.0.1:54341/ok/dev1", BASE + "/ok/dev1"]);
  const req3 = await submit("TEST001");
  await dispatch(store, keys, { extraHosts });
  const ob3 = (await q("select status, last_error from app.push_outbox where request_id = $1", [req3]))[0];
  check("R3 連線失敗 → 排程重試（不會誤判為成功）", ob3.status === "PENDING" && /NETWORK_ERROR|TIMEOUT/.test(ob3.last_error ?? ""), JSON.stringify(ob3));
  await q("update app.push_subscriptions set endpoint = $1 where endpoint = $2", [BASE + "/ok/dev1", "http://127.0.0.1:54341/ok/dev1"]);

  // 第 5 次仍失敗 → FAILED（不無限重試）
  mode = { "/ok/": 503 };
  for (let i = 0; i < 5; i++) {
    await q("update app.push_outbox set next_attempt_at = now() where request_id = $1", [req3]);
    await dispatch(store, keys, { extraHosts });
  }
  const ob3b = (await q("select status, attempts from app.push_outbox where request_id = $1", [req3]))[0];
  check("R4 連續失敗達 5 次 → FAILED，停止重試", ob3b.status === "FAILED" && ob3b.attempts === 5, JSON.stringify(ob3b));
  mode = {};

  // ---------- 4. SSRF：不在允許清單的 endpoint 不會被連線
  const calls: string[] = [];
  const spy = (async (u: string | URL | Request) => { calls.push(String(u)); return new Response(null, { status: 201 }); }) as typeof fetch;
  await q(`update app.push_subscriptions set endpoint = 'https://169.254.169.254/latest/meta-data' where endpoint = $1`, [BASE + "/ok/dev1"]);
  const req4 = await submit("TEST002");
  await dispatch(store, keys, { fetchImpl: spy });
  check("S11 資料庫遭寫入內部位址時，發送端拒絕連線且停用該訂閱",
    calls.length === 0 && (await q("select revoke_reason from app.push_subscriptions where endpoint like 'https://169.254%'"))[0].revoke_reason === "EXPIRED");
  check("S12 允許清單：FCM／Apple／Mozilla／Windows 可、其他主機與非 HTTPS 不可",
    endpointAllowed("https://fcm.googleapis.com/fcm/send/x") && endpointAllowed("https://web.push.apple.com/x")
    && endpointAllowed("https://updates.push.services.mozilla.com/wpush/v2/x") && endpointAllowed("https://db5p.notify.windows.com/w/?token=x")
    && !endpointAllowed("https://fcm.googleapis.com.evil.com/x") && !endpointAllowed("http://fcm.googleapis.com/x")
    && !endpointAllowed("https://fcm.googleapis.com:8443/x") && !endpointAllowed("https://user@fcm.googleapis.com/x")
    && !endpointAllowed("https://127.0.0.1/x"));
  void req4;
} catch (e) {
  check("FATAL", false, (e as Error).stack ?? String(e));
} finally {
  server.close();
  await pool.end();
  const passed = results.filter((r) => r.ok).length;
  console.log(`\n${passed}/${results.length} passed`);
  process.exitCode = passed === results.length ? 0 : 1;
}
