// V5.9 Safari 相容性最小驗證：Playwright WebKit＋iPhone 13 設定（隔離環境，只測產品搜尋與手動輸入）
// 用法：PLAYWRIGHT_BROWSERS_PATH=<含 webkit 的資料夾> node webkit-safari.cjs <輸出資料夾>
const { webkit, devices } = require("playwright");
const out = process.argv[2];
const B = "http://127.0.0.1:4173";
const results = [];
const check = (group, name, ok, detail = "") => { results.push({ group, name, ok: !!ok, detail }); console.log(`${ok ? "PASS" : "FAIL"} [${group}] ${name}${detail ? " — " + detail : ""}`); };

(async () => {
  const browser = await webkit.launch();
  const ctx = await browser.newContext({ ...devices["iPhone 13"] });
  const page = await ctx.newPage();
  const jsErrors = [];
  page.on("pageerror", (e) => jsErrors.push("page: " + e.message));
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource/.test(m.text())) jsErrors.push("console: " + m.text()); });

  check("環境", "瀏覽器", true, `WebKit ${browser.version()}｜${await page.evaluate(() => navigator.userAgent)}`);
  // 登入（以觸控點按）
  await page.goto(B + "/#/");
  await page.fill("#no", "TEST001"); await page.fill("#pw", "LocalTest#2026");
  await page.locator('button:has-text("登入")').tap();
  await page.waitForSelector(".nav-tabs", { timeout: 20000 });
  await page.goto(B + "/#/new");
  const frameEl = await page.waitForSelector("iframe.r8-form");
  const frame = await frameEl.contentFrame();
  await frame.waitForSelector("#q0");
  // 表單 iframe 內另掛錯誤監聽（確保 iframe 內的例外也被記錄）
  await frame.evaluate(() => { window.__errs = []; window.addEventListener("error", (e) => window.__errs.push(e.message)); window.addEventListener("unhandledrejection", (e) => window.__errs.push(String(e.reason))); });
  const f = page.frameLocator("iframe.r8-form");
  const view = async (sel) => {
    await page.evaluate(() => document.querySelector("iframe.r8-form").scrollIntoView());
    await f.locator(sel).evaluate((el) => { el.scrollIntoView({ block: "start" }); el.ownerDocument.defaultView.scrollBy(0, -12); });
  };
  const overflow = async () => {
    const pg = await page.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
    const fr = await frame.evaluate(() => [document.documentElement.scrollWidth, innerWidth]);
    return { ok: pg[0] <= pg[1] && fr[0] <= fr[1], text: `頁面 ${pg[0]}/${pg[1]}，表單 ${fr[0]}/${fr[1]}` };
  };
  const fontSize = await f.locator("#q0").evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
  check("環境", "搜尋欄字級 ≥ 16px（避免 iOS 自動放大）", fontSize >= 16, `${fontSize}px`);

  // ---------- 1. 搜尋產品
  await view("#q0");
  await f.locator("#q0").tap();
  await f.locator("#q0").fill("F26509");
  await f.locator("#r0 .presult").first().waitFor({ timeout: 15000 });
  const codes = await f.locator("#r0 .presult .pc").allTextContents();
  check("產品搜尋", "部分產品編碼 F26509", codes.length === 8 && codes.includes("L6-F26509A-1"), `${codes.length} 筆：${codes.slice(0, 4).join(", ")}…`);
  await f.locator("#q0").fill("槽鋼 2000");
  await f.waitForFunction?.(() => true);
  await page.waitForTimeout(600);
  await f.locator("#r0 .presult .pn").first().waitFor();
  const names = await f.locator("#r0 .presult .pn").allTextContents();
  check("產品搜尋", "品名關鍵字「槽鋼 2000」", names.length === 20 && names.every((n) => n.includes("槽鋼") && n.includes("2000")), `${names.length} 筆＋顯示更多`);
  const box = await f.locator("#r0").boundingBox();
  const vp = page.viewportSize();
  check("產品搜尋", "結果清單顯示於畫面內", (await f.locator("#r0").isVisible()) && box.width > 0 && box.width <= vp.width, `寬 ${Math.round(box.width)}px／視窗 ${vp.width}px`);
  await page.screenshot({ path: `${out}/safari-1-搜尋結果.png` });

  // ---------- 2. 自動帶入（以編碼搜尋後點按）
  await f.locator("#q0").fill("L6-F26509A-1");
  await f.locator('#r0 .presult:has(.pc:text-is("L6-F26509A-1"))').waitFor();
  const shown = await f.locator('#r0 .presult:has(.pc:text-is("L6-F26509A-1"))').evaluate((el) => [el.querySelector(".pn").textContent, el.querySelector(".ps")?.textContent ?? ""]);
  await f.locator('#r0 .presult:has(.pc:text-is("L6-F26509A-1"))').tap();
  const code0 = await f.locator("#code0").inputValue(), name0 = await f.locator("#name0").inputValue();
  check("自動帶入", "產品編碼", code0 === "L6-F26509A-1", code0);
  check("自動帶入", "品名／規格（與搜尋結果一致）", name0 === `${shown[0]} / ${shown[1].replace("規格：", "")}` && name0 === "踏板265x900mm含舌片 / 熱浸", name0);
  check("自動帶入", "顯示「已由產品主檔帶入」", (await f.locator(".picked").count()) === 1);
  check("自動帶入", "結果清單點選後關閉", (await f.locator("#r0").count()) === 0 || !(await f.locator("#r0").isVisible()));
  await f.locator(".picked").evaluate((el) => el.scrollIntoView({ block: "center" }));
  await page.screenshot({ path: `${out}/safari-2-自動帶入.png` });

  // ---------- 3. 第二筆產品
  await f.locator("#add").tap();
  await f.locator("#q1").waitFor();
  await view("#q1");
  await f.locator("#q1").tap();
  await f.locator("#q1").fill("蜂巢鋼牆模牙叉套");
  await f.locator("#r1 .presult").first().waitFor();
  const specs = await f.locator("#r1 .presult .ps").allTextContents();
  check("第二筆產品", "搜尋結果正常（同名不同規格）", specs.length === 2, specs.join("｜"));
  let o = await overflow();
  check("第二筆產品", "結果展開時無橫向溢出", o.ok, o.text);
  await page.screenshot({ path: `${out}/safari-3-第二筆搜尋.png` });
  await f.locator("#r1 .presult").nth(1).tap();
  check("第二筆產品", "點選帶入第二個規格", (await f.locator("#name1").inputValue()) === "蜂巢鋼牆模牙叉套 / 藍漆 1900mm", await f.locator("#name1").inputValue());
  await f.locator("#remark1").tap();
  await f.locator("#remark1").type("Safari 輸入測試");
  check("第二筆產品", "輸入欄位可正常輸入（產品備註）", (await f.locator("#remark1").inputValue()) === "Safari 輸入測試");
  check("第二筆產品", "第一筆資料未被影響", (await f.locator("#code0").inputValue()) === "L6-F26509A-1");
  await f.locator("#add").tap(); await f.locator("#q2").waitFor();
  await view("#q2"); await f.locator("#q2").fill("L6-F26509A-1");
  await f.locator("#r2 .presult").first().waitFor();
  check("第二筆產品", "同案已選產品不可再選（已在本案）", await f.locator('#r2 .presult:has(.pc:text-is("L6-F26509A-1"))').isDisabled());
  o = await overflow();
  check("第二筆產品", "三筆產品時無橫向溢出", o.ok, o.text);

  // ---------- 4. 手動輸入
  await f.locator("#q2").fill("查無此產品ZZZ");
  await f.locator("#r2 .pmsg").waitFor();
  check("手動輸入", "搜尋不存在產品顯示可手動輸入", (await f.locator("#r2 .pmsg").textContent()).includes("手動輸入"));
  await page.screenshot({ path: `${out}/safari-4a-找不到提示遮住欄位.png` });
  // 直接點按下方「產品編碼」欄（真實使用者操作）
  let direct = true;
  try { await f.locator("#code2").tap({ timeout: 3000 }); } catch { direct = false; }
  const cover = await f.locator("#code2").evaluate((el) => { const r = el.getBoundingClientRect(); const hit = el.ownerDocument.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return hit === el ? "無" : (hit.className || hit.tagName); });
  check("手動輸入", "找不到時可直接點按下方產品編碼欄", direct, direct ? "" : `被「${cover}」遮住；點按提示框本身也不會關閉`);
  if (!direct) {
    // 迴避方式：點按搜尋區以外的地方關閉提示框，再點按產品編碼欄
    await f.locator(".product").nth(2).locator(".product-head").tap();
    check("手動輸入", "迴避方式：點按其他位置關閉提示後可點按編碼欄", !(await f.locator("#r2").isVisible()));
    await f.locator("#code2").tap();
  }
  await f.locator("#code2").type("MANUAL-001");
  await f.locator("#name2").tap(); await f.locator("#name2").type("手動品名 / 手動規格");
  check("手動輸入", "可手動輸入編碼、品名及規格", (await f.locator("#code2").inputValue()) === "MANUAL-001" && (await f.locator("#name2").inputValue()) === "手動品名 / 手動規格");
  await page.screenshot({ path: `${out}/safari-4-手動輸入.png` });
  await f.locator("#purpose").selectOption("施工使用");
  await f.locator("#code2").fill("MANUAL×1");
  await f.locator("#check").tap();
  check("手動輸入", "V5.8 編碼驗證：含 × 的手動編碼被擋", (await f.locator("#result").textContent()).includes("產品編碼只允許"), (await f.locator("#result").textContent()).slice(0, 60));
  await f.locator("#code2").fill("MANUAL 1");
  await f.locator("#check").tap();
  check("手動輸入", "V5.8 編碼驗證：含空白的手動編碼被擋", (await f.locator("#result").textContent()).includes("產品編碼只允許"));
  check("手動輸入", "V5.8 編碼驗證：最多 30 字（maxlength）", (await f.locator("#code2").getAttribute("maxlength")) === "30");
  await f.locator("#code2").fill("MANUAL-001");
  await f.locator("#check").tap();
  await f.locator("#modal.show").waitFor();
  const modal = await f.locator("#modalBody").textContent();
  check("手動輸入", "合規手動編碼通過驗證，確認視窗列出 3 筆", modal.includes("L6-F26509A-1") && modal.includes("FA-150751900-5") && modal.includes("MANUAL-001"));
  await page.screenshot({ path: `${out}/safari-5-確認視窗.png` });
  await f.locator("#acceptModal").tap();
  await page.waitForSelector("text=首次申請已送出", { timeout: 20000 });
  check("手動輸入", "送出成功（隔離資料庫）", true);

  // ---------- JavaScript 錯誤
  const frameErrs = await frame.evaluate(() => window.__errs).catch(() => []); // 送出後 iframe 可能已移除
  check("JavaScript", "Safari JavaScript 錯誤", jsErrors.length === 0 && frameErrs.length === 0, [...jsErrors, ...frameErrs].join("；") || "0 個");
  await browser.close();
  require("fs").writeFileSync(`${out}/safari-results.json`, JSON.stringify(results, null, 2));
  console.log(`\n${results.filter((r) => r.ok).length}/${results.length} passed`);
})().catch((e) => { console.error("FATAL", e.message); process.exit(1); });
