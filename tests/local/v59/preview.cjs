// V5.9 UI 預覽截圖＋手機檢查（隔離環境）
const { chromium, devices } = require("playwright");
const fs = require("fs");
const [out, dir] = process.argv.slice(2);
const B = "http://127.0.0.1:4173";
const res = [];
const check = (n, ok, d = "") => { res.push({ n, ok: !!ok, d }); console.log(`${ok ? "PASS" : "FAIL"} ${n}${d ? " — " + d : ""}`); };
const file = (p, name) => ({ name, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: fs.readFileSync(p) });

async function login(page, no) {
  await page.goto(B + "/#/");
  await page.fill("#no", no); await page.fill("#pw", "LocalTest#2026");
  await page.click('button:has-text("登入")');
  await page.waitForSelector(".nav-tabs", { timeout: 15000 });
}
async function upload(page, f) {
  await page.setInputFiles("input[type=file]", f);
  await page.waitForSelector(".pm-preview", { timeout: 30000 });
}

(async () => {
  const br = await chromium.launch();
  // ---------- 管理員（桌面）：正式檔同步、不完整檔高風險、錯誤檔
  {
    const ctx = await br.newContext({ viewport: { width: 1366, height: 900 }, deviceScaleFactor: 2 });
    const page = await ctx.newPage();
    await login(page, "TEST006");
    await page.goto(B + "/#/admin/products"); await page.waitForSelector("text=Excel 完整同步");
    await upload(page, file(`${dir}/products.xlsx`, "產品編碼對照表(2).xlsx"));
    await page.screenshot({ path: `${out}/01-管理員-匯入預覽-桌面.png`, fullPage: true });
    page.once("dialog", (d) => d.accept());
    await page.click('button:has-text("確認同步產品主檔")'); await page.waitForSelector(".okmsg");
    await page.waitForFunction(() => document.querySelector(".r8-meter strong")?.textContent === "7,004");

    await upload(page, file(`${dir}/incomplete.xlsx`, "不完整清單.xlsx"));
    const risk = await page.textContent(".pm-riskbox");
    check("不完整檔：顯示高風險警告（預計停用 1,000 筆）", risk.includes("預計停用 1,000 筆"), risk.slice(0, 60));
    check("高風險：未勾選與輸入確認前不能同步", await page.isDisabled('button:has-text("確認同步產品主檔")'));
    await page.check(".pm-riskbox input[type=checkbox]"); await page.fill(".pm-riskbox input:not([type=checkbox])", "確認停用");
    check("高風險：完成兩項確認後才可同步", await page.isEnabled('button:has-text("確認同步產品主檔")'));
    await page.uncheck(".pm-riskbox input[type=checkbox]");
    await page.locator(".pm-preview").screenshot({ path: `${out}/02-管理員-高風險警告-桌面.png` });
    await page.click('button:has-text("取消")');

    await upload(page, file(`${dir}/broken.xlsx`, "錯誤清單.xlsx"));
    const errs = await page.$$eval(".pm-preview tbody tr", (rs) => rs.map((r) => r.textContent));
    check("錯誤檔：列出錯誤列且不提供同步按鈕", errs.length === 3 && !(await page.locator('button:has-text("確認同步產品主檔")').count()), errs.join(" | "));
    await page.locator(".pm-preview").screenshot({ path: `${out}/03-管理員-錯誤檔案-桌面.png` });
    await ctx.close();
  }
  // ---------- 員工：iPhone／Android／桌面
  for (const [label, opts] of [["iPhone", devices["iPhone 13"]], ["Android", devices["Pixel 7"]], ["桌面", { viewport: { width: 1366, height: 900 }, deviceScaleFactor: 2 }]]) {
    const ctx = await br.newContext(opts);
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST001");
    await page.goto(B + "/#/new");
    const frame = page.frameLocator("iframe.r8-form");
    await frame.locator("#q0").waitFor();
    // 讓搜尋框位於可視範圍（外層頁面捲到表單、表單內捲到搜尋框）
    await page.evaluate(() => document.querySelector("iframe.r8-form").scrollIntoView());
    await frame.locator("#q0").evaluate((el) => el.scrollIntoView({ block: "start" }));
    await frame.locator("#q0").evaluate((el) => el.ownerDocument.defaultView.scrollBy(0, -12));
    await frame.locator("#q0").fill("槽鋼 2000");
    await frame.locator("#r0 .presult").first().waitFor();
    const n = await frame.locator("#r0 .presult").count();
    check(`${label}：搜尋「槽鋼 2000」顯示結果與「顯示更多」`, n === 20 && (await frame.locator("#r0 .pmore").count()) === 1, `${n} 筆`);
    const tap = await frame.locator("#r0 .presult").first().boundingBox();
    check(`${label}：結果按鈕高度 ≥ 44px（易點選）`, tap.height >= 44, `${Math.round(tap.height)}px`);
    await page.screenshot({ path: `${out}/1${label === "iPhone" ? 1 : label === "Android" ? 2 : 3}-員工-搜尋結果-${label}.png` });
    await frame.locator("#r0 .presult").first().click();
    check(`${label}：點選後帶入並顯示「已由產品主檔帶入」`, (await frame.locator(".picked").count()) === 1);
    await frame.locator(".picked").evaluate((el) => el.scrollIntoView({ block: "center" }));
    await page.screenshot({ path: `${out}/1${label === "iPhone" ? 4 : label === "Android" ? 5 : 6}-員工-已帶入-${label}.png` });
    const sw = await page.evaluate(() => document.documentElement.scrollWidth), vw = await page.evaluate(() => innerWidth);
    const fsw = await frame.locator("body").evaluate((b) => [b.ownerDocument.documentElement.scrollWidth, b.ownerDocument.defaultView.innerWidth]);
    check(`${label}：頁面與表單皆無橫向捲動`, sw <= vw && fsw[0] <= fsw[1], `${sw}/${vw} · 表單 ${fsw.join("/")}`);
    check(`${label}：無 JS 錯誤`, errors.length === 0, errors.join("; "));
    await ctx.close();
  }
  await br.close();
  fs.writeFileSync(`${out}/preview-results.json`, JSON.stringify(res, null, 2));
  console.log(`\n${res.filter((r) => r.ok).length}/${res.length} passed`);
})().catch((e) => { console.error("FATAL", e.message); process.exit(1); });
