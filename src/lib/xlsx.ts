/**
 * 輕量 .xlsx 讀取器（僅供產品主檔匯入）：直接解析 Excel 內部 XML，不經任何數值轉換。
 * - 文字儲存格（shared / inline string）原樣讀出，保留前導零與大小寫。
 * - 數值儲存格讀取 XML 內儲存的原始文字（不轉成浮點數）；若格式為補零（例如 00000）則依格式補零，並回報數量供管理員核對。
 * - 只讀第一個工作表；第一列為欄名。所有資料驗證在後端執行。
 */
import { unzipSync, strFromU8 } from "fflate";

export interface ProductSheet {
  sheetName: string;
  header: string[];
  rows: { row: number; code: string | null; name: string | null; spec: string | null }[];
  numericCells: number;
}

const NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

function xml(files: Record<string, Uint8Array>, path: string): Document | null {
  const f = files[path];
  return f ? new DOMParser().parseFromString(strFromU8(f), "application/xml") : null;
}
const text = (el: Element) => Array.from(el.getElementsByTagNameNS(NS, "t")).map((t) => t.textContent ?? "").join("");
const colIndex = (ref: string) => {
  let n = 0;
  for (const ch of ref.replace(/\d+$/, "")) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
};

export async function readProductSheet(file: File): Promise<ProductSheet> {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(new Uint8Array(await file.arrayBuffer()));
  } catch {
    throw new Error("無法讀取檔案：請上傳 Excel 活頁簿（.xlsx）");
  }
  const wb = xml(files, "xl/workbook.xml");
  const firstSheet = wb?.getElementsByTagNameNS(NS, "sheet")[0];
  if (!wb || !firstSheet) throw new Error("檔案中找不到工作表");
  const relId = firstSheet.getAttributeNS(REL, "id");
  const rels = xml(files, "xl/_rels/workbook.xml.rels");
  const target = Array.from(rels?.getElementsByTagName("Relationship") ?? []).find((r) => r.getAttribute("Id") === relId)?.getAttribute("Target") ?? "worksheets/sheet1.xml";
  const sheetPath = target.startsWith("/") ? target.slice(1) : "xl/" + target.replace(/^\.\//, "");
  const sheet = xml(files, sheetPath);
  if (!sheet) throw new Error("工作表內容遺失");

  const shared = Array.from(xml(files, "xl/sharedStrings.xml")?.getElementsByTagNameNS(NS, "si") ?? []).map(text);
  // 樣式：找出補零格式（例如 000000），數值儲存格依位數補零
  const styles = xml(files, "xl/styles.xml");
  const fmt = new Map<number, string>();
  for (const n of Array.from(styles?.getElementsByTagNameNS(NS, "numFmt") ?? [])) fmt.set(+n.getAttribute("numFmtId")!, n.getAttribute("formatCode") ?? "");
  const xfFmt = Array.from(styles?.getElementsByTagNameNS(NS, "cellXfs")[0]?.getElementsByTagNameNS(NS, "xf") ?? []).map((x) => +(x.getAttribute("numFmtId") ?? 0));

  let numericCells = 0;
  const grid: { row: number; cells: (string | null)[] }[] = [];
  for (const r of Array.from(sheet.getElementsByTagNameNS(NS, "row"))) {
    const cells: (string | null)[] = [];
    for (const c of Array.from(r.getElementsByTagNameNS(NS, "c"))) {
      const t = c.getAttribute("t") ?? "n";
      const v = c.getElementsByTagNameNS(NS, "v")[0]?.textContent ?? null;
      let value: string | null;
      if (t === "s") value = v === null ? null : shared[+v] ?? null;
      else if (t === "inlineStr") value = text(c);
      else if (t === "str" || t === "b" || t === "e") value = v;
      else {
        value = v;
        if (v !== null) {
          numericCells++;
          const code = fmt.get(xfFmt[+(c.getAttribute("s") ?? 0)] ?? 0) ?? "";
          if (/^0+$/.test(code) && /^\d+$/.test(v)) value = v.padStart(code.length, "0");
        }
      }
      cells[colIndex(c.getAttribute("r") ?? "A1")] = value;
    }
    grid.push({ row: +(r.getAttribute("r") ?? grid.length + 1), cells });
  }
  if (grid.length === 0) return { sheetName: firstSheet.getAttribute("name") ?? "", header: [], rows: [], numericCells };

  const header = Array.from(grid[0].cells, (h) => (h ?? "").trim());
  const col = (name: string) => header.indexOf(name);
  const [ci, ni, si] = [col("產品代碼"), col("品名"), col("規格")];
  const rows = grid.slice(1)
    .filter((g) => g.cells.some((x) => x !== null && x !== undefined && x.trim() !== ""))   // 略過完全空白列
    .map((g) => ({ row: g.row, code: ci < 0 ? null : g.cells[ci] ?? null, name: ni < 0 ? null : g.cells[ni] ?? null, spec: si < 0 ? null : g.cells[si] ?? null }));
  return { sheetName: firstSheet.getAttribute("name") ?? "", header, rows, numericCells };
}

export async function sha256(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
