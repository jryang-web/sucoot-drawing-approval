// 隔離 UI 測試用 API 橋接（僅本機 127.0.0.1:54329）
// - /auth/v1/token：Supabase Auth 測試替身（驗證 auth.users 的 bcrypt 密碼、建立 session、簽發 HS256 JWT）
// - /rest/v1/rpc/<fn>：以 authenticated 角色＋JWT claims 執行（與 PostgREST 相同的權限情境）
// - 其他 /rest/v1 查詢：本測試不涵蓋，回傳空集合
import http from "node:http";
import crypto from "node:crypto";
import pg from "pg";

const pool = new pg.Pool({ host: "/var/lib/postgresql/sucoot-v59/run", port: 54330, user: "postgres", database: "postgres", max: 20 });
const SECRET = crypto.randomBytes(32);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const mac = (data) => crypto.createHmac("sha256", SECRET).update(data).digest("base64url");
const sign = (payload) => { const h = b64({ alg: "HS256", typ: "JWT" }); const b = b64(payload); return `${h}.${b}.${mac(`${h}.${b}`)}`; };
function verify(token) {
  const [h, b, s] = (token || "").split(".");
  if (!s) return null;
  const expected = mac(`${h}.${b}`);
  if (s.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(s), Buffer.from(expected))) return null;
  const p = JSON.parse(Buffer.from(b, "base64url").toString());
  return p.exp > Date.now() / 1000 ? p : null;
}
const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { "Content-Type": "application/json", ...headers });
  res.end(body === undefined ? "" : JSON.stringify(body));
};
// 先收集完整位元組再一次以 UTF-8 解碼（逐段轉字串會把跨段的中文字切壞）
const readBody = (req) => new Promise((resolve) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => { const d = Buffer.concat(chunks).toString("utf8"); resolve(d ? JSON.parse(d) : {}); });
});

let pushKicks = 0, pushFail = false;
const fnCache = new Map();
async function overloads(name) {
  if (!fnCache.has(name)) {
    const { rows } = await pool.query(
      `select p.proargnames as names, array(select format_type(t, null) from unnest(p.proargtypes) t) as types, p.proretset as is_set,
              (select t.typtype from pg_type t where t.oid = p.prorettype) as rettype
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1`, [name]);
    fnCache.set(name, rows);
  }
  return fnCache.get(name);
}

async function asUser(claims, work) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims ?? {})]);
    await c.query(claims ? "set local role authenticated" : "set local role anon");
    const result = await work(c);
    await c.query("commit");
    return result;
  } catch (e) {
    await c.query("rollback").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname === "/auth/v1/token" && req.method === "POST") {
    const body = await readBody(req);
    if (url.searchParams.get("grant_type") !== "password") return send(res, 400, { error: "unsupported_grant_type" });
    const { rows } = await pool.query(
      `select id, email from auth.users where email = lower($1)
          and encrypted_password = extensions.crypt($2, encrypted_password) and (banned_until is null or banned_until < now())`,
      [body.email, body.password]);
    if (!rows.length) return send(res, 400, { error: "invalid_grant", error_description: "Invalid login credentials" });
    const session = (await pool.query("insert into auth.sessions (user_id) values ($1) returning id", [rows[0].id])).rows[0];
    const exp = Math.floor(Date.now() / 1000) + 3600;
    const user = { id: rows[0].id, aud: "authenticated", role: "authenticated", email: rows[0].email };
    return send(res, 200, {
      access_token: sign({ sub: user.id, role: "authenticated", session_id: session.id, exp }),
      token_type: "bearer", expires_in: 3600, expires_at: exp, refresh_token: crypto.randomUUID(), user,
    });
  }
  if (url.pathname === "/auth/v1/user") {
    const p = verify((req.headers.authorization || "").replace(/^Bearer /, ""));
    return p ? send(res, 200, { id: p.sub, aud: "authenticated", role: "authenticated" }) : send(res, 401, { message: "invalid JWT" });
  }
  if (url.pathname === "/auth/v1/logout") return send(res, 204);

  const claims = verify((req.headers.authorization || "").replace(/^Bearer /, ""));
  const m = url.pathname.match(/^\/rest\/v1\/rpc\/([a-z0-9_]+)$/);
  if (m && req.method === "POST") {
    const body = await readBody(req);
    const keys = Object.keys(body);
    const fn = (await overloads(m[1])).find((o) => keys.every((k) => (o.names || []).includes(k)));
    if (!fn) return send(res, 404, { code: "PGRST202", message: `function ${m[1]} not found` });
    const args = keys.map((k, i) => `${k} => $${i + 1}::${fn.types[fn.names.indexOf(k)]}`).join(", ");
    const vals = keys.map((k) => (/json/.test(fn.types[fn.names.indexOf(k)]) ? JSON.stringify(body[k]) : body[k]));
    // 與 PostgREST 相同：回傳 setof 純量（例如 setof uuid）時輸出純量陣列，setof 表格型別時輸出物件陣列
    const out = await asUser(claims, async (c) => (fn.is_set
      ? (fn.rettype === "b"
          ? (await c.query(`select x as v from public.${m[1]}(${args}) x`, vals)).rows.map((r) => r.v)
          : (await c.query(`select * from public.${m[1]}(${args})`, vals)).rows)
      : (await c.query(`select to_jsonb(public.${m[1]}(${args})) as r`, vals)).rows[0].r));
    return send(res, 200, out);
  }
  // 唯讀查詢子集：select=欄位、欄位=eq/neq/in/is、order、limit/offset（以使用者權限與 RLS 執行）
  const t = url.pathname.match(/^\/rest\/v1\/([a-z_][a-z0-9_]*)$/);
  if (t && (req.method === "GET" || req.method === "HEAD")) {
    const ident = (x) => { if (!/^[a-z_][a-z0-9_]*$/.test(x)) throw Object.assign(new Error("bad identifier " + x), { code: "PGRST100" }); return `"${x}"`; };
    const sel = (url.searchParams.get("select") || "*").split(",").map((c) => (c === "*" ? "*" : ident(c.trim()))).join(", ");
    const where = []; const vals = []; let order = ""; let limit = ""; let offset = "";
    for (const [k, v] of url.searchParams) {
      if (k === "select") continue;
      if (k === "order") { order = " order by " + v.split(",").map((o) => { const [c, d] = o.split("."); return ident(c) + (d === "desc" ? " desc" : " asc"); }).join(", "); continue; }
      if (k === "limit") { limit = ` limit ${parseInt(v, 10)}`; continue; }
      if (k === "offset") { offset = ` offset ${parseInt(v, 10)}`; continue; }
      const [op, ...rest] = v.split("."); const val = rest.join(".");
      if (op === "eq" || op === "neq") { vals.push(val); where.push(`${ident(k)}::text ${op === "eq" ? "=" : "<>"} $${vals.length}`); }
      else if (op === "in") { vals.push(val.replace(/^\(|\)$/g, "").split(",")); where.push(`${ident(k)}::text = any($${vals.length})`); }
      else if (op === "is") where.push(`${ident(k)} is ${val === "null" ? "null" : val === "true" ? "true" : "false"}`);
      else return send(res, 400, { code: "PGRST100", message: "unsupported filter " + op });
    }
    const sql = `select ${sel} from public.${ident(t[1])}${where.length ? " where " + where.join(" and ") : ""}${order}${limit}${offset}`;
    const rows = await asUser(claims, async (c) => (await c.query(sql, vals)).rows);
    return send(res, 200, req.method === "HEAD" ? undefined : rows, { "Content-Range": `0-${Math.max(rows.length - 1, 0)}/${rows.length}` });
  }
  if (url.pathname.startsWith("/rest/v1/")) return send(res, 200, [], { "Content-Range": "*/0" });
  // V5.9.1：push-dispatch Edge Function 測試替身（GET 公鑰；POST 需有效登入，記錄觸發次數；可切換為失敗模式）
  if (url.pathname === "/functions/v1/push-dispatch") {
    if (req.method === "OPTIONS") return send(res, 204);
    if (req.method === "GET") return send(res, 200, { publicKey: process.env.TEST_VAPID_PUBLIC_KEY || null });
    if (!claims) return send(res, 401, { error: "UNAUTHORIZED" });
    pushKicks++;
    return pushFail ? send(res, 500, { error: "DISPATCH_FAILED" }) : send(res, 200, { batches: 0, events: 0, accepted: 0, failed: 0, no_subscription: 0 });
  }
  if (url.pathname === "/__test/push") {   // 測試控制：查詢觸發次數、切換失敗模式
    if (url.searchParams.has("fail")) pushFail = url.searchParams.get("fail") === "1";
    if (url.searchParams.has("reset")) pushKicks = 0;
    return send(res, 200, { kicks: pushKicks, fail: pushFail });
  }
  return send(res, 404, { message: "not found" });
}

http.createServer((req, res) => {
  handle(req, res).catch((e) => send(res, e.code === "42501" ? 401 : 400, { code: e.code ?? "P0001", message: e.message, details: null, hint: null }));
}).listen(54329, "127.0.0.1", () => console.log("bridge listening on 127.0.0.1:54329"));
