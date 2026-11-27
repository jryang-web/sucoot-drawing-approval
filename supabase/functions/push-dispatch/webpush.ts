// SUCOOT V5.9.1 | Web Push（RFC 8291 aes128gcm 加密＋RFC 8292 VAPID）
// 只使用 WebCrypto，不依賴第三方套件；Supabase Edge（Deno）與 Node 22 皆可執行。
// 本檔不讀取環境變數、不輸出任何日誌；VAPID 私鑰由呼叫端傳入。

const enc = new TextEncoder();

export function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function b64urlDecode(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

// HKDF（單一區塊，輸出 ≤ 32 bytes）
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const prk = await hmac(salt, ikm);
  return (await hmac(prk, concat(info, new Uint8Array([1])))).slice(0, length);
}

export interface VapidKeys { publicKey: string; privateKey: string; subject: string }
export interface PushTarget { endpoint: string; p256dh: string; auth: string }

// VAPID 公鑰：65 bytes 未壓縮點；私鑰：32 bytes d（皆為 base64url）
async function vapidSigningKey(keys: VapidKeys): Promise<CryptoKey> {
  const pub = b64urlDecode(keys.publicKey);
  if (pub.length !== 65 || pub[0] !== 4) throw new Error("VAPID_PUBLIC_KEY_INVALID");
  const d = b64urlDecode(keys.privateKey);
  if (d.length !== 32) throw new Error("VAPID_PRIVATE_KEY_INVALID");
  return crypto.subtle.importKey("jwk", {
    kty: "EC", crv: "P-256", d: keys.privateKey,
    x: b64urlEncode(pub.slice(1, 33)), y: b64urlEncode(pub.slice(33, 65)), ext: false,
  }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export async function vapidAuthorization(endpoint: string, keys: VapidKeys, ttlSeconds = 12 * 3600): Promise<string> {
  const aud = new URL(endpoint).origin;
  const header = b64urlEncode(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64urlEncode(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + ttlSeconds, sub: keys.subject })));
  const unsigned = `${header}.${claims}`;
  // WebCrypto 的 ECDSA 簽章即為 JWS 需要的 r||s（64 bytes）格式
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await vapidSigningKey(keys), enc.encode(unsigned)));
  return `vapid t=${unsigned}.${b64urlEncode(sig)}, k=${keys.publicKey}`;
}

// RFC 8291：以裝置公鑰（p256dh）與 auth secret 加密，產生單一紀錄的 aes128gcm 內容
export async function encryptPayload(target: PushTarget, plaintext: Uint8Array): Promise<Uint8Array> {
  const uaPublic = b64urlDecode(target.p256dh);
  const authSecret = b64urlDecode(target.auth);
  if (uaPublic.length !== 65 || uaPublic[0] !== 4) throw new Error("SUBSCRIPTION_KEY_INVALID");
  if (authSecret.length !== 16) throw new Error("SUBSCRIPTION_AUTH_INVALID");
  if (plaintext.length > 3800) throw new Error("PAYLOAD_TOO_LARGE");

  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));

  const ikm = await hkdf(authSecret, shared, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);

  const key = await crypto.subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(plaintext, new Uint8Array([2]))));

  const rs = new Uint8Array(4);
  new DataView(rs.buffer).setUint32(0, 4096);
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

// 只允許已知的瀏覽器推播服務（與資料庫 app.push_endpoint_allowed 相同規則）
const ALLOWED_HOST = /^(fcm\.googleapis\.com|android\.googleapis\.com|web\.push\.apple\.com|[a-z0-9-]+\.push\.apple\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.notify\.windows\.com)$/;

export function endpointAllowed(endpoint: string, extraHosts: string[] = []): boolean {
  try {
    const u = new URL(endpoint);
    if (u.username || u.password) return false;
    // 僅供隔離測試：明確列出的本機假推播服務（Edge Function 不傳入此參數）
    if (extraHosts.includes(u.host)) return true;
    return u.protocol === "https:" && !u.port && ALLOWED_HOST.test(u.hostname);
  } catch {
    return false;
  }
}

export interface SendResult { http_status: number | null; accepted: boolean; gone: boolean; error?: string }

export async function sendWebPush(target: PushTarget, payload: unknown, keys: VapidKeys,
  opts: { ttl?: number; urgency?: "normal" | "high"; topic?: string; timeoutMs?: number; extraHosts?: string[]; fetchImpl?: typeof fetch } = {}): Promise<SendResult> {
  if (!endpointAllowed(target.endpoint, opts.extraHosts)) return { http_status: null, accepted: false, gone: true, error: "ENDPOINT_NOT_ALLOWED" };
  let body: Uint8Array;
  try {
    body = await encryptPayload(target, enc.encode(JSON.stringify(payload)));
  } catch (e) {
    return { http_status: null, accepted: false, gone: true, error: (e as Error).message.slice(0, 60) };
  }
  const headers: Record<string, string> = {
    "Content-Encoding": "aes128gcm",
    "Content-Type": "application/octet-stream",
    TTL: String(opts.ttl ?? 86400),
    Urgency: opts.urgency ?? "normal",
    Authorization: await vapidAuthorization(target.endpoint, keys),
  };
  if (opts.topic) headers.Topic = opts.topic;   // 同主題未送達的舊通知由推播服務取代
  try {
    const res = await (opts.fetchImpl ?? fetch)(target.endpoint, {
      method: "POST", headers, body, redirect: "manual", signal: AbortSignal.timeout(opts.timeoutMs ?? 10000),
    });
    await res.body?.cancel().catch(() => {});
    const accepted = res.status >= 200 && res.status < 300;
    return { http_status: res.status, accepted, gone: res.status === 404 || res.status === 410,
             error: accepted ? undefined : `HTTP_${res.status}` };
  } catch (e) {
    return { http_status: null, accepted: false, gone: false, error: (e as Error).name === "TimeoutError" ? "TIMEOUT" : "NETWORK_ERROR" };
  }
}
