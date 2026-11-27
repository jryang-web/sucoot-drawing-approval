// SUCOOT V5.9.1｜角標、推播前端與 Service Worker 隔離測試（Playwright：Chromium 桌面／手機、WebKit iPhone）
// 前置：tests/local/v59/regress.sh 建立隔離資料庫與 API 橋接；npm run build && npx vite preview --port 4173
// 執行：node tests/local/v591/ui.cjs <輸出資料夾> [webkit 瀏覽器資料夾]
// 注意：Badging API 以「呼叫紀錄」驗證（無頭瀏覽器沒有桌面圖示），不代表實機圖示已顯示。
const { chromium, webkit, devices } = require("playwright");
const fs = require("fs");
const crypto = require("crypto");
const pg = require("./node_modules/pg");

const [out = "."] = process.argv.slice(2);
const B = "http://127.0.0.1:4173";
const BRIDGE = "http://127.0.0.1:54329";
const PW = "LocalTest#2026";
const pool = new pg.Pool({ host: "/var/lib/postgresql/sucoot-v59/run", port: 54330, user: "postgres", database: "postgres" });
const res = [];
const check = (n, ok, d = "") => { res.push({ n, ok: !!ok, d }); console.log(`${ok ? "PASS" : "FAIL"} ${n}${d ? " — " + d : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const q = async (sql, p = []) => (await pool.query(sql, p)).rows;

async function asEmployee(no, sql, params = []) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query(`select set_config('request.jwt.claims', jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text, true)
                     from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
                    where e.employee_no = $1`, [no]);
    await c.query("set local role authenticated");
    const r = await c.query(sql, params); await c.query("commit");
    return r.rows[0] && r.rows[0].r;
  } catch (e) { await c.query("rollback"); throw e; } finally { c.release(); }
}
async function submitAs(no) {
  const key = crypto.randomUUID();
  await asEmployee(no, "select public.prepare_operation($1, 'write_r8_application', $2::jsonb) as r", [key, JSON.stringify({
    p_purpose: "角標測試", p_urgent: false, p_reason: null, p_note: null, p_submit: true, p_id: null, p_version: null,
    p_products: [{ code: "UI-" + key.slice(0, 6), name: "角標測試" }] })]);
  const o = await asEmployee(no, "select public.execute_operation($1) as r", [key]);
  if (!o.ok) throw new Error("submit failed " + JSON.stringify(o));
  return o.id;
}
const total = async (no) => (await q("select (app.badge_counts(id)->>'total')::int n from public.employees where employee_no = $1", [no]))[0].n;

// 在頁面載入前替換 Badging API，紀錄呼叫（unsupported=true 時移除 API，模擬不支援的瀏覽器）
const badgeSpy = (unsupported) => `(() => {
  window.__badge = [];
  const proto = Object.getPrototypeOf(navigator);
  if (${unsupported}) { delete proto.setAppBadge; delete proto.clearAppBadge; delete navigator.setAppBadge; delete navigator.clearAppBadge; return; }
  Object.defineProperty(proto, "setAppBadge", { configurable: true, value: (n) => { window.__badge.push(["set", n]); return Promise.resolve(); } });
  Object.defineProperty(proto, "clearAppBadge", { configurable: true, value: () => { window.__badge.push(["clear"]); return Promise.resolve(); } });
})();`;
const lastBadge = (page) => page.evaluate(() => window.__badge.at(-1));

async function login(page, no) {
  await page.goto(B + "/#/my");
  await page.fill("#no", no); await page.fill("#pw", PW);
  await page.click('button:has-text("登入")');
  await page.waitForSelector(".nav-tabs", { timeout: 20000 });
  await page.waitForFunction(() => document.querySelector('[aria-label="通知與角標"]')?.textContent.includes("最後同步"), null, { timeout: 15000 });
}
const navCount = (page) => page.evaluate(() => document.querySelector(".nav-count")?.textContent ?? "");
const cardNumbers = (page) => page.$$eval('[aria-label="通知與角標"] .r8-meter strong', (s) => s.map((x) => x.textContent));
async function hideShow(page) {
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
    document.dispatchEvent(new Event("visibilitychange"));
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
    document.dispatchEvent(new Event("visibilitychange"));
  });
}

(async () => {
  await fetch(BRIDGE + "/__test/push?fail=0&reset=1");
  const br = await chromium.launch({ channel: "chromium" });   // 完整 Chromium（新版無頭模式），支援通知 API

  // ================= Chromium 桌面：TEST003（部門主管）
  {
    const ctx = await br.newContext({ viewport: { width: 1366, height: 900 } });
    await ctx.addInitScript(badgeSpy(false));
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    const calls = []; page.on("request", (r) => { if (r.url().includes("my_badge_summary")) calls.push(Date.now()); });

    await submitAs("TEST001");                                   // 確保 TEST003 至少有一件第一層待審
    await login(page, "TEST003");
    let expect = await total("TEST003");
    check("T13 登入／開啟 App 時取得計數並設定角標", JSON.stringify(await lastBadge(page)) === JSON.stringify(["set", expect]) && (await navCount(page)) === String(expect),
      `角標 ${JSON.stringify(await lastBadge(page))}、資料庫 ${expect}`);
    const nums = await cardNumbers(page);
    check("C1 App 內顯示未讀、待辦、合計（替代圖示角標的一致顯示）", nums[2] === String(expect) && Number(nums[0]) + Number(nums[1]) === expect, nums.join("/"));
    await page.waitForFunction((n) => document.querySelector("h2")?.ownerDocument.body.textContent.includes(`目前待辦（${n}）`), Number(nums[1]), { timeout: 10000 }).catch(() => {});
    const homeText = await page.textContent(".r8-screen");
    check("C10 工作首頁「目前待辦（N）」與角標的待辦案件數一致（同一案件只列一次）", homeText.includes(`目前待辦（${nums[1]}）`), (homeText.match(/目前待辦（\d+）/) || [""])[0]);
    await page.screenshot({ path: `${out}/01-桌面-工作首頁-角標.png`, fullPage: false });

    // T14：背景期間有新案件 → 返回前景時更新
    await submitAs("TEST002");
    expect = await total("TEST003");
    await hideShow(page);
    await page.waitForFunction((n) => window.__badge.at(-1)?.[1] === n, expect, { timeout: 8000 }).catch(() => {});
    check("T14 App 返回前景時重新取得計數並更新角標", JSON.stringify(await lastBadge(page)) === JSON.stringify(["set", expect]) && (await navCount(page)) === String(expect),
      `${JSON.stringify(await lastBadge(page))} vs ${expect}`);

    // 去重：短時間內多次觸發只發出合併後的查詢
    const n0 = calls.length;
    await page.evaluate(() => { for (let i = 0; i < 10; i++) window.dispatchEvent(new Event("sucoot-badge-refresh")); });
    await sleep(1500);
    check("C2 連續 10 次同步要求被合併（不大量重複查詢）", calls.length - n0 <= 2, `${calls.length - n0} 次查詢`);

    // T17＋操作後同步：推播發送端故障時，經前端正式送件仍成功；送件後重新計算角標（本人為製造部主管，自己的案件亦列第一層待審）
    await fetch(BRIDGE + "/__test/push?fail=1&reset=1");
    const mine0 = (await q("select count(*)::int n from public.drawing_requests r join public.employees e on e.id = r.applicant_id where e.employee_no = 'TEST003' and r.status <> 'DRAFT'"))[0].n;
    await page.click('a:has-text("新增申請")');
    const f = page.frameLocator("iframe.r8-form");
    await f.locator("#code0").fill("UI-PUSH-01"); await f.locator("#name0").fill("推播故障測試");
    await f.locator("#purpose").selectOption("施工使用");
    await f.locator("#check").click(); await f.locator("#acceptModal").click();
    const submitted = await page.waitForSelector("text=首次申請已送出", { timeout: 20000 }).then(() => true).catch(() => false);
    await sleep(1500);
    const mine1 = (await q("select count(*)::int n from public.drawing_requests r join public.employees e on e.id = r.applicant_id where e.employee_no = 'TEST003' and r.status <> 'DRAFT'"))[0].n;
    const kicks = (await (await fetch(BRIDGE + "/__test/push")).json()).kicks;
    check("T17 推播發送端回 500 時，正式送件仍成功提交並顯示成功", submitted && mine1 === mine0 + 1, `送件 ${mine0} → ${mine1}`);
    check("T17 送件後有觸發推播發送；失敗被忽略、不中斷操作", kicks >= 1, `觸發 ${kicks} 次`);
    let after = await total("TEST003");
    await page.waitForFunction((n) => window.__badge.at(-1)?.[1] === n, after, { timeout: 8000 }).catch(() => {});
    check("C9 完成案件操作後自動重新計算角標", (await lastBadge(page))?.[1] === after, `${JSON.stringify(await lastBadge(page))} vs ${after}`);
    await fetch(BRIDGE + "/__test/push?fail=0");

    // T03（前端）：在其他裝置完成第一層核准後，返回此裝置前景 → 角標下降
    const req = (await q(`select r.id, r.version from public.drawing_requests r join public.departments d on d.id = r.department_id
                           where r.status = 'PENDING_DEPT_REVIEW' and d.code = 'MFG' order by r.created_at limit 1`))[0];
    const before = await total("TEST003");
    const key = crypto.randomUUID();
    await asEmployee("TEST003", "select public.prepare_operation($1, 'review_level1', $2::jsonb) as r",
      [key, JSON.stringify({ p_id: req.id, p_action: "APPROVE", p_expected_version: req.version })]);
    await asEmployee("TEST003", "select public.execute_operation($1) as r", [key]);
    after = await total("TEST003");
    await sleep(1600);
    await hideShow(page);
    await page.waitForFunction((n) => window.__badge.at(-1)?.[1] === n || (n === 0 && window.__badge.at(-1)?.[0] === "clear"), after, { timeout: 8000 }).catch(() => {});
    check("T03 完成待辦後角標下降（前端）", after === before - 1 && ((await lastBadge(page))?.[1] ?? 0) === after, `${before} → ${after}，角標 ${JSON.stringify(await lastBadge(page))}`);
    await page.goto(`${B}/#/my`);

    // T04（前端）：通知標記已讀 → 角標下降
    const emp = (await q("select id from public.employees where employee_no = 'TEST003'"))[0].id;
    const aid = (await q("insert into public.admin_audit_logs (actor_id, action, target_type, target_id) values ($1, 'UI_TEST_NOTICE', 'test', 'x') returning id", [emp]))[0].id;
    await q("insert into app.personal_security_notices (audit_id, employee_id, event, occurred_at) values ($1, $2, 'change', now())", [aid, emp]);
    await page.reload(); await page.waitForSelector('button:has-text("標為已讀")', { timeout: 15000 });
    await page.waitForFunction((n) => window.__badge.at(-1)?.[1] === n, after + 1, { timeout: 8000 }).catch(() => {});
    const withUnread = (await lastBadge(page))?.[1];
    await page.click('button:has-text("標為已讀")');
    await page.waitForFunction((n) => (window.__badge.at(-1)?.[1] ?? 0) === n || (n === 0 && window.__badge.at(-1)?.[0] === "clear"), after, { timeout: 8000 }).catch(() => {});
    check("T04 通知標記已讀後角標下降（前端）", withUnread === after + 1 && ((await lastBadge(page))?.[1] ?? 0) === after,
      `${withUnread} → ${JSON.stringify(await lastBadge(page))}`);

    // 離線：不把舊數字當成即時資料
    await ctx.setOffline(true);
    await page.evaluate(() => window.dispatchEvent(new Event("offline")));
    await page.waitForFunction(() => document.querySelector('[aria-label="通知與角標"] [role=status]')?.textContent.includes("離線"), null, { timeout: 5000 }).catch(() => {});
    const offlineText = await page.textContent('[aria-label="通知與角標"] [role=status]');
    check("C3 離線時標示「目前離線，以上為某時間的資料」", offlineText.includes("目前離線"), offlineText);
    await page.screenshot({ path: `${out}/02-桌面-離線提示.png` });
    await ctx.setOffline(false);
    await page.evaluate(() => window.dispatchEvent(new Event("online")));
    await page.waitForFunction(() => document.querySelector('[aria-label="通知與角標"] [role=status]')?.textContent.includes("最後同步"), null, { timeout: 8000 }).catch(() => {});
    check("C4 恢復連線後自動重新同步", (await page.textContent('[aria-label="通知與角標"] [role=status]')).includes("最後同步"));

    // T15：登出清除角標；換帳號只顯示新帳號計數
    await page.click("button.logout");
    await page.waitForSelector("#no", { timeout: 15000 });
    check("T15 登出時清除角標", JSON.stringify(await lastBadge(page)) === JSON.stringify(["clear"]) && (await navCount(page)) === "", JSON.stringify(await lastBadge(page)));
    await login(page, "TEST005");
    const t5 = await total("TEST005");
    check("T15 換帳號（TEST005）只顯示自己的計數", (await lastBadge(page))?.[1] === t5 || (t5 === 0 && (await lastBadge(page))?.[0] === "clear"),
      `${JSON.stringify(await lastBadge(page))} vs ${t5}`);
    check("C5 無 JavaScript 錯誤（Chromium 桌面）", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // ================= T16：不支援 Badging API 的瀏覽器
  {
    const ctx = await br.newContext({ viewport: { width: 1366, height: 900 } });
    await ctx.addInitScript(badgeSpy(true));
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST001");
    const txt = await page.textContent('[aria-label="通知與角標"]');
    check("T16 不支援 Badging API：說明以頁面數字為準、App 內計數照常顯示、無錯誤",
      txt.includes("不支援 App 圖示角標") && (await cardNumbers(page))[2] === String(await total("TEST001")) && errors.length === 0, errors.join("; "));
    await page.click('a:has-text("新增申請")'); await page.waitForSelector("iframe.r8-form");
    check("T16 不支援時其他功能正常（可進入新增申請）", errors.length === 0);
    await ctx.close();
  }

  // ================= 推播尚未設定（伺服器未設定 Secrets）：不顯示會失敗的「啟用通知」按鈕
  // 本機模式 API 與網站同網域，需停用 Service Worker 才能攔截請求（正式環境 API 為不同網域，不經 Service Worker）
  {
    const ctx = await br.newContext({ ...devices["Pixel 7"], serviceWorkers: "block" });
    await ctx.grantPermissions(["notifications"], { origin: B });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await page.route("**/functions/v1/push-dispatch", (r) => r.request().method() === "GET"
      ? r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ publicKey: null }) }) : r.continue());
    await login(page, "TEST001");
    await page.waitForFunction(() => document.querySelector('[aria-label="通知與角標"]')?.textContent.includes("尚未開放"), null, { timeout: 10000 }).catch(() => {});
    const txt = await page.textContent('[aria-label="通知與角標"]');
    check("C11 伺服器尚未設定推播：顯示「背景通知尚未開放」、不顯示啟用按鈕，App 內計數照常",
      txt.includes("背景通知尚未開放") && (await page.locator('button:has-text("啟用通知")').count()) === 0 && txt.includes("最後同步") && errors.length === 0, txt.slice(0, 160));
    await page.screenshot({ path: `${out}/08-推播尚未開放.png` });
    await page.click("button.logout"); await page.waitForSelector("#no");
    check("C12 登入頁只顯示「忘記密碼請聯絡系統管理員」（AGENTS.md 1.3）", (await page.textContent("form, .loggedout, main")).includes("忘記密碼請聯絡系統管理員")
      && !(await page.textContent("body")).includes("帳號由系統管理員建立"));
    await ctx.close();
  }

  // ================= T20：Service Worker 推播與通知點擊（Chromium 手機模擬）
  {
    const ctx = await br.newContext({ ...devices["Pixel 7"] });
    await ctx.grantPermissions(["notifications"], { origin: B });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST004");
    await page.evaluate(() => navigator.serviceWorker.ready);
    const sw = ctx.serviceWorkers()[0] ?? await ctx.waitForEvent("serviceworker");
    const cdp = await ctx.newCDPSession(page);
    const regs = [];
    cdp.on("ServiceWorker.workerRegistrationUpdated", (e) => regs.push(...e.registrations));
    await cdp.send("ServiceWorker.enable"); await sleep(500);
    const registrationId = regs.find((r) => r.scopeURL.startsWith(B))?.registrationId;
    const reqId = (await q("select id from public.drawing_requests order by created_at desc limit 1"))[0].id;
    const deliver = async (data) => {
      await page.evaluate(async () => { for (const n of await (await navigator.serviceWorker.ready).getNotifications()) n.close(); });
      await cdp.send("ServiceWorker.deliverPushMessage", { origin: B + "/", registrationId, data: JSON.stringify(data) });
      await sleep(800);
      return page.evaluate(async () => (await (await navigator.serviceWorker.ready).getNotifications()).map((n) => ({ title: n.title, body: n.body, tag: n.tag, data: n.data })));
    };
    // 在 Service Worker 內記錄 setAppBadge 呼叫
    await sw.evaluate(() => {
      self.__swBadge = [];
      Object.defineProperty(Object.getPrototypeOf(self.navigator), "setAppBadge", { configurable: true, value: (n) => { self.__swBadge.push(n); return Promise.resolve(); } });
      Object.defineProperty(Object.getPrototypeOf(self.navigator), "clearAppBadge", { configurable: true, value: () => { self.__swBadge.push(0); return Promise.resolve(); } });
    });
    const refreshMsgs = page.evaluate(() => new Promise((r) => {
      navigator.serviceWorker.addEventListener("message", (e) => { if (e.data?.type === "SUCOOT_BADGE_REFRESH") r(true); });
      setTimeout(() => r(false), 4000);
    }));
    const n1 = await deliver({ v: 1, badge: 7, title: "SUCOOT 圖面申請", body: "有 1 件「第二層待審」案件等待處理", url: `#/r/${reqId}`, tag: "sucoot-pending" });
    check("T20 Service Worker 收到推播：顯示通知、標籤與點擊路由正確", registrationId && n1.length === 1 && n1[0].data?.url === `#/r/${reqId}` && n1[0].tag === "sucoot-pending", JSON.stringify(n1));
    check("T20 Service Worker 收到推播：以推播中的數字更新圖示角標", JSON.stringify(await sw.evaluate(() => self.__swBadge)) === "[7]", JSON.stringify(await sw.evaluate(() => self.__swBadge)));
    check("T20 Service Worker 通知已開啟的 App 重新同步計數", await refreshMsgs);
    const n2 = await deliver({ v: 1, badge: 1, title: "x", body: "y", url: "https://evil.example.com/#/my" });
    check("T20 外部網址不會被當成點擊路由（改為工作首頁）", n2[0]?.data?.url === "#/my", JSON.stringify(n2));
    await cdp.send("ServiceWorker.deliverPushMessage", { origin: B + "/", registrationId, data: "not-json" }); await sleep(800);
    const n3 = await page.evaluate(async () => (await (await navigator.serviceWorker.ready).getNotifications()).map((n) => ({ title: n.title, data: n.data })));
    check("T20 內容無法解析時仍顯示一般通知（不造成錯誤）", n3.some((n) => n.title === "SUCOOT 圖面申請" && n.data?.url === "#/my"), JSON.stringify(n3));

    // 通知點擊：以合成事件呼叫 Service Worker 的 notificationclick 處理（無法以程式點擊系統通知）
    await deliver({ v: 1, badge: 7, title: "t", body: "b", url: `#/r/${reqId}` });
    await page.goto(B + "/#/my"); await page.waitForSelector(".nav-tabs");
    await sw.evaluate(async () => {
      const [n] = await self.registration.getNotifications();
      try { self.dispatchEvent(new NotificationEvent("notificationclick", { notification: n })); } catch (e) { /* 合成事件的 waitUntil 可能被拒絕 */ }
    });
    await page.waitForFunction((id) => location.hash === `#/r/${id}`, reqId, { timeout: 5000 }).catch(() => {});
    check("T20 通知點擊：已開啟的 App 切換到案件明細（HashRouter 路由）", (await page.evaluate(() => location.hash)) === `#/r/${reqId}`, await page.evaluate(() => location.hash));
    await page.screenshot({ path: `${out}/03-Android模擬-通知點擊後案件頁.png` });

    // 啟用通知按鈕（使用者點擊後才要求權限；隔離環境無法連線 FCM）
    await page.goto(B + "/#/my"); await page.waitForSelector('[aria-label="通知與角標"]');
    const btn = page.locator('button:has-text("啟用通知")');
    check("C6 有「啟用通知」按鈕；頁面載入時未自動要求權限", await btn.count() === 1);
    await btn.click();
    await page.waitForSelector('[aria-label="通知與角標"] [role=alert]', { timeout: 20000 }).catch(() => {});
    const msg = await page.textContent('[aria-label="通知與角標"] [role=alert]').catch(() => "");
    const subs = (await q("select count(*)::int n from app.push_subscriptions s join public.employees e on e.id = s.employee_id where e.employee_no = 'TEST004' and s.revoked_at is null"))[0].n;
    check("C7 按下啟用通知：取得權限並嘗試建立瀏覽器訂閱（結果如實顯示）", !!msg, `訊息：「${msg}」；資料庫有效訂閱 ${subs} 筆`);
    await page.screenshot({ path: `${out}/04-Android模擬-啟用通知結果.png` });
    check("C8 無 JavaScript 錯誤（Chromium 手機模擬）", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // ================= T24：manifest 與圖示（Chromium 手機模擬）
  {
    const ctx = await br.newContext({ ...devices["Pixel 7"] });
    const page = await ctx.newPage();
    await page.goto(B + "/#/my"); await page.waitForSelector("#no");
    const cdp = await ctx.newCDPSession(page);
    const man = await cdp.send("Page.getAppManifest");
    const parsed = JSON.parse(man.data || "{}");
    check("T24 manifest 可解析、無錯誤", man.errors.length === 0, JSON.stringify(man.errors));
    const sizes = {};
    for (const p of ["icons/icon-192.png", "icons/icon-512.png", "icons/maskable-512.png", "icons/apple-touch-icon.png", "icons/favicon-32.png"]) {
      const b = Buffer.from(await (await fetch(`${B}/${p}`)).arrayBuffer());
      sizes[p] = b.readUInt32BE(16) + "x" + b.readUInt32BE(20);
    }
    check("T24 圖示尺寸：192、512、maskable 512、Apple 180、favicon 32",
      sizes["icons/icon-192.png"] === "192x192" && sizes["icons/icon-512.png"] === "512x512" && sizes["icons/maskable-512.png"] === "512x512"
      && sizes["icons/apple-touch-icon.png"] === "180x180" && sizes["icons/favicon-32.png"] === "32x32", JSON.stringify(sizes));
    check("T24 manifest 含 any 192／512 與 maskable 512", parsed.icons?.some((i) => i.sizes === "512x512" && i.purpose === "maskable")
      && parsed.icons?.some((i) => i.sizes === "192x192") && parsed.icons?.some((i) => i.sizes === "512x512" && i.purpose === "any"));
    const links = await page.$$eval("link[rel~=icon], link[rel=apple-touch-icon], link[rel=manifest]", (ls) => ls.map((l) => l.getAttribute("rel") + "=" + l.getAttribute("href")));
    check("T24 HTML 正確引用 manifest、favicon、Apple touch icon", ["manifest=./manifest.webmanifest", "icon=./icons/favicon-32.png", "apple-touch-icon=./icons/apple-touch-icon.png"].every((x) => links.includes(x)), links.join(" "));
    const sw = await (await fetch(B + "/sw.js")).text();
    check("T24 Service Worker 預先快取圖示，且未快取 Supabase 資料", ["icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png"].every((x) => sw.includes(x))
      && sw.includes("url.origin !== self.location.origin"));
    await ctx.close();
  }
  // ================= 管理員推播發送紀錄（唯讀、無敏感資料）
  {
    const ctx = await br.newContext({ viewport: { width: 1366, height: 900 } });
    const page = await ctx.newPage();
    await login(page, "TEST006");
    await page.goto(B + "/#/admin/push");
    await page.waitForSelector("text=推播發送紀錄", { timeout: 15000 });
    await page.waitForSelector(".tablewrap tbody tr", { timeout: 15000 }).catch(() => {});
    const body = await page.textContent(".r8-screen");
    const rows = await page.locator(".tablewrap tbody tr").count();
    check("A1 系統管理員可查看推播發送紀錄（狀態、嘗試次數、原因）", rows > 0 && body.includes("推播服務已接受"), `${rows} 列`);
    check("A2 紀錄頁不顯示 endpoint、金鑰或通知內容", !/googleapis|apple\.com|127\.0\.0\.1:5434|p256dh|有 1 件/.test(body));
    await page.screenshot({ path: `${out}/07-管理員-推播發送紀錄.png`, fullPage: true });
    await page.click("button.logout"); await page.waitForSelector("#no");
    await login(page, "TEST001");
    await page.goto(B + "/#/admin/push"); await sleep(1000);
    check("A3 一般員工開啟推播紀錄網址會被導回工作首頁", (await page.evaluate(() => location.hash)) === "#/my");
    await ctx.close();
  }
  await br.close();

  // ================= T22：WebKit iPhone 13 模擬
  {
    const wb = await webkit.launch();
    const ctx = await wb.newContext({ ...devices["iPhone 13"] });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST001");
    const txt = await page.textContent('[aria-label="通知與角標"]');
    const t1 = await total("TEST001");
    check("T22 WebKit iPhone：App 內計數正確", (await cardNumbers(page))[2] === String(t1), `${(await cardNumbers(page))[2]} vs ${t1}`);
    check("T22 WebKit iPhone（設定檔為 iOS 15）：說明需 iOS 16.4 以上、並提示「標記」設定", txt.includes("iOS 16.4 以上才支援") && txt.includes("標記"), txt.slice(0, 200));
    check("T22 WebKit iPhone：未加入主畫面時不顯示啟用按鈕、不要求權限", await page.locator('button:has-text("啟用通知")').count() === 0);
    await page.screenshot({ path: `${out}/05-iPhone模擬-通知與角標.png`, fullPage: false });
    const sw = await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth);
    check("T22 WebKit iPhone：無橫向捲動", sw);
    await page.click("button.logout"); await page.waitForSelector("#no");
    check("T22 WebKit iPhone：登入／登出與角標同步無 JavaScript 錯誤", errors.length === 0, errors.join("; "));
    await ctx.close();
    // iOS 17（未加入主畫面）：應說明須先加入主畫面
    const ctx17 = await wb.newContext({ ...devices["iPhone 13"], userAgent: devices["iPhone 13"].userAgent.replace(/OS 15_0/, "OS 17_5").replace(/Version\/15\.0/, "Version/17.5") });
    const p17 = await ctx17.newPage();
    await login(p17, "TEST001");
    const t17 = await p17.textContent('[aria-label="通知與角標"]');
    check("T22 WebKit iPhone（iOS 17、未加入主畫面）：說明須先「加入主畫面」再從主畫面開啟", t17.includes("加入主畫面") && !(await p17.locator('button:has-text("啟用通知")').count()), t17.slice(0, 200));
    await p17.screenshot({ path: `${out}/06-iPhone模擬-iOS17-需加入主畫面.png` });
    await ctx17.close(); await wb.close();
  }

  await pool.end();
  fs.writeFileSync(`${out}/ui-results.json`, JSON.stringify(res, null, 2));
  console.log(`\n${res.filter((r) => r.ok).length}/${res.length} passed`);
  process.exitCode = res.every((r) => r.ok) ? 0 : 1;
})().catch(async (e) => { console.error("FATAL", e); await pool.end().catch(() => {}); process.exit(1); });
