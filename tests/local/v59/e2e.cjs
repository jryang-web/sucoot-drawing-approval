// V5.9 隔離 UI 端對端測試（本機 127.0.0.1 預覽＋隔離資料庫）
const { chromium, devices } = require("playwright");
const [out, xlsx] = process.argv.slice(2);
const B = "http://127.0.0.1:4173";
const results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok: !!ok, detail }); console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " — " + detail : ""}`); };

async function login(page, no) {
  await page.goto(B + "/#/");
  await page.fill("#no", no);
  await page.fill("#pw", "LocalTest#2026");
  await page.click('button:has-text("登入")');
  await page.waitForSelector(".nav-tabs", { timeout: 15000 });
}

(async () => {
  const br = await chromium.launch();

  // ---------------- 管理員：Excel 匯入（桌面）
  {
    const ctx = await br.newContext({ viewport: { width: 1366, height: 900 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST006");
    await page.goto(B + "/#/admin/products");
    await page.waitForSelector("text=產品主檔管理");
    await page.setInputFiles('input[type=file]', { name: '產品編碼對照表(2).xlsx',
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: require('fs').readFileSync(xlsx) });
    await page.waitForSelector(".pm-preview", { timeout: 30000 });
    const counts = await page.$$eval(".pm-counts .r8-meter", (els) => Object.fromEntries(els.map((e) => [e.querySelector("span").textContent, e.querySelector("strong").textContent])));
    check("管理員預覽：Excel 總筆數 7,004、新增 7,004、錯誤 0", counts["Excel 總筆數"] === "7,004" && counts["新增"] === "7,004" && counts["錯誤"] === "0", JSON.stringify(counts));
    check("預覽提醒：17 組大小寫不同編碼", (await page.textContent(".pm-warn summary")).includes("17 組"));
    await page.screenshot({ path: `${out}/admin-preview-desktop.png`, fullPage: true });
    page.once("dialog", (d) => d.accept());
    await page.click('button:has-text("確認同步產品主檔")');
    await page.waitForSelector(".okmsg", { timeout: 30000 });
    check("確認同步完成", (await page.textContent(".okmsg")).includes("新增 7004"), await page.textContent(".okmsg"));
    await page.waitForFunction(() => document.querySelector(".r8-meter strong")?.textContent === "7,004");
    await page.screenshot({ path: `${out}/admin-done-desktop.png`, fullPage: true });
    check("管理員頁面無 JS 錯誤", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // ---------------- 員工：新增申請＋產品搜尋（iPhone）
  {
    const ctx = await br.newContext({ ...devices["iPhone 13"] });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await login(page, "TEST001");
    await page.goto(B + "/#/new");
    const f = page.frameLocator("iframe.r8-form");
    await f.locator("#q0").waitFor();

    // 1) 以編碼片段搜尋並選取
    await f.locator("#q0").fill("F26509");
    await f.locator("#r0 .presult").first().waitFor();
    const codes = await f.locator("#r0 .presult .pc").allTextContents();
    check("編碼片段搜尋 F26509", codes.includes("L6-F26509A-1") && codes.includes("L6-F26509a-1"), codes.join(", "));
    await page.screenshot({ path: `${out}/employee-search-phone.png` });
    await f.locator('#r0 .presult:has(.pc:text-is("L6-F26509A-1"))').click();
    check("點選後自動帶入編碼", (await f.locator("#code0").inputValue()) === "L6-F26509A-1");
    check("點選後自動帶入品名／規格", (await f.locator("#name0").inputValue()) === "踏板265x900mm含舌片 / 熱浸", await f.locator("#name0").inputValue());

    // 2) 第二筆：同名不同規格（以品名＋規格關鍵字）
    await f.locator("#add").click();
    await f.locator("#q1").fill("蜂巢鋼牆模牙叉套");
    await f.locator("#r1 .presult").first().waitFor();
    const specs = await f.locator("#r1 .presult .ps").allTextContents();
    check("同名不同規格皆列出並顯示規格", specs.length >= 2, specs.join(" | "));
    await f.locator("#r1 .presult").nth(1).click();
    check("選到第二個規格", (await f.locator("#name1").inputValue()).includes(" / "), await f.locator("#name1").inputValue());

    // 3) 第三筆：含 × 的正式編碼（V5.8 手動規則不允許，主檔選取允許）
    await f.locator("#add").click();
    await f.locator("#q2").fill("55×2");
    await f.locator("#r2 .presult").first().waitFor();
    await f.locator("#r2 .presult").first().click();
    check("含 × 的主檔編碼可選取", (await f.locator("#code2").inputValue()) === "GB-75-B-150-55×2-B");

    // 4) 第四筆：重複編碼不可選
    await f.locator("#add").click();
    await f.locator("#q3").fill("L6-F26509A-1");
    await f.locator("#r3 .presult").first().waitFor();
    check("同案已選產品顯示「已在本案」且不可點選", await f.locator('#r3 .presult:has(.pc:text-is("L6-F26509A-1"))').isDisabled());

    // 5) 找不到 → 手動輸入
    await f.locator("#q3").fill("查無此產品ZZZ");
    await f.locator("#r3 .pmsg").waitFor();
    check("找不到時提示可手動輸入", (await f.locator("#r3 .pmsg").textContent()).includes("手動輸入"));
    await f.locator("#code3").fill("MANUAL-001");
    await f.locator("#name3").fill("手動輸入測試品");
    await page.screenshot({ path: `${out}/employee-form-phone.png`, fullPage: true });

    // 6) 手動輸入含 × 的編碼 → 仍依 V5.8 規則擋下
    await f.locator("#code3").fill("MANUAL×1");
    await f.locator("#purpose").selectOption("施工使用");
    await f.locator("#check").click();
    check("手動輸入不合規編碼仍被擋（V5.8 規則不變）", (await f.locator("#result").textContent()).includes("產品編碼只允許"));
    await f.locator("#code3").fill("MANUAL-001");

    // 7) 送出
    await f.locator("#check").click();
    await f.locator("#acceptModal").click();
    await page.waitForSelector("text=首次申請已送出", { timeout: 20000 });
    check("案件送出成功", true);
    await page.screenshot({ path: `${out}/employee-submitted-phone.png` });
    const sw = await page.evaluate(() => document.documentElement.scrollWidth), vw = await page.evaluate(() => innerWidth);
    check("手機無橫向捲動", sw <= vw, `${sw}/${vw}`);
    check("員工頁面無 JS 錯誤", errors.length === 0, errors.join("; "));
    await ctx.close();
  }
  await br.close();
  require("fs").writeFileSync(`${out}/e2e-results.json`, JSON.stringify(results, null, 2));
  console.log(`\n${results.filter((r) => r.ok).length}/${results.length} passed`);
})().catch((e) => { console.error("FATAL", e.message); process.exit(1); });
