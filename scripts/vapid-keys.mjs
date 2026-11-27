#!/usr/bin/env node
// SUCOOT V5.9.1｜VAPID 金鑰與排程密鑰產生／驗證工具（由公司授權系統維護人員在自己的電腦執行）
//
//   node scripts/vapid-keys.mjs generate <資料夾>            產生三個檔案（僅擁有者可讀），畫面只顯示公鑰
//   node scripts/vapid-keys.mjs verify   <資料夾> [subject]  驗證公私鑰配對與 VAPID_SUBJECT 格式（不顯示私鑰）
//
// 安全設計：
// - 私鑰與排程密鑰只寫入檔案（權限 600、資料夾 700），不輸出到畫面、不出現在指令列，因此不會進入終端機歷史。
// - 不覆寫既有檔案；不連網；只使用 Node.js 內建 crypto。
// - 填入 Supabase 後，請依發布文件刪除這三個檔案；請勿放在 repo 目錄內。
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const FILES = { pub: "vapid_public_key.txt", priv: "vapid_private_key.txt", cron: "push_cron_secret.txt" };
const die = (msg) => { console.error("錯誤：" + msg); process.exit(1); };
const [cmd, dirArg, subject] = process.argv.slice(2);
if (!cmd || !dirArg || !["generate", "verify"].includes(cmd)) {
  die("用法：node scripts/vapid-keys.mjs generate <資料夾>｜verify <資料夾> [VAPID_SUBJECT]");
}
const dir = path.resolve(dirArg);
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
if (dir === repoRoot || dir.startsWith(repoRoot + path.sep)) die("請勿把金鑰放在專案資料夾內（避免被提交到 GitHub）");

const fingerprint = (s) => crypto.createHash("sha256").update(s).digest("hex").slice(0, 12);

function publicFromJwk(jwk) {
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]).toString("base64url");
}

if (cmd === "generate") {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const f of Object.values(FILES)) if (fs.existsSync(path.join(dir, f))) die(`${f} 已存在，為避免覆蓋既有金鑰，請改用新的資料夾`);
  const { privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = privateKey.export({ format: "jwk" });
  const pub = publicFromJwk(jwk);
  const write = (f, v) => fs.writeFileSync(path.join(dir, f), v + "\n", { mode: 0o600, flag: "wx" });
  write(FILES.pub, pub);
  write(FILES.priv, jwk.d);                                         // 32 bytes，base64url
  write(FILES.cron, crypto.randomBytes(32).toString("base64url"));  // 256 bits
  console.log("已產生（檔案僅擁有者可讀）：");
  for (const f of Object.values(FILES)) console.log("  " + path.join(dir, f));
  console.log("\nVAPID_PUBLIC_KEY（公開值，可顯示）：\n" + pub);
  console.log("\n私鑰與排程密鑰未顯示在畫面上。下一步：node scripts/vapid-keys.mjs verify " + dirArg + " <VAPID_SUBJECT>");
  process.exit(0);
}

// verify
const read = (f) => { try { return fs.readFileSync(path.join(dir, f), "utf8").trim(); } catch { return die(`找不到 ${f}`); } };
const pub = read(FILES.pub), priv = read(FILES.priv), cron = read(FILES.cron);
const results = [];
const ok = (name, pass, note = "") => { results.push(pass); console.log(`${pass ? "✔" : "✘"} ${name}${note ? "（" + note + "）" : ""}`); };

ok("VAPID_PUBLIC_KEY 格式（65 bytes 未壓縮 P-256 公鑰）", /^[A-Za-z0-9_-]{87}$/.test(pub) && Buffer.from(pub, "base64url")[0] === 4);
ok("VAPID_PRIVATE_KEY 格式（32 bytes）", /^[A-Za-z0-9_-]{43}$/.test(priv));
let paired = false;
try {
  const raw = Buffer.from(pub, "base64url");
  const key = crypto.createPrivateKey({ format: "jwk", key: { kty: "EC", crv: "P-256", d: priv,
    x: raw.subarray(1, 33).toString("base64url"), y: raw.subarray(33, 65).toString("base64url") } });
  const pubKey = crypto.createPublicKey({ format: "jwk", key: { kty: "EC", crv: "P-256",
    x: raw.subarray(1, 33).toString("base64url"), y: raw.subarray(33, 65).toString("base64url") } });
  const probe = crypto.randomBytes(32);
  paired = crypto.verify("sha256", probe, pubKey, crypto.sign("sha256", probe, key));
} catch { paired = false; }
ok("公私鑰配對（以私鑰簽章、公鑰驗證）", paired);
ok("PUSH_CRON_SECRET 長度 ≥ 32 字元", cron.length >= 32);
for (const [f] of [[FILES.priv], [FILES.cron]]) {
  const mode = fs.statSync(path.join(dir, f)).mode & 0o777;
  if (process.platform !== "win32") ok(`${f} 權限僅擁有者可讀寫`, (mode & 0o077) === 0, mode.toString(8));
}
if (subject !== undefined) {
  const valid = /^mailto:[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(subject) || /^https:\/\/[^\s/?#]+\.[^\s/?#]+(\/\S*)?$/.test(subject);
  ok("VAPID_SUBJECT 格式（mailto: 信箱或 https: 網址）", valid);
}
console.log(`\n公鑰：${pub}`);
console.log(`私鑰指紋（SHA-256 前 12 碼，供核對用，非私鑰本身）：${fingerprint(priv)}`);
process.exit(results.every(Boolean) ? 0 : 1);
