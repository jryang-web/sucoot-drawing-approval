// 申請紀錄報表（圖管人員）：一筆圖面一列，依送出日期區間查詢；可列印（含另存 PDF）或下載 Excel
import { useState, type FormEvent } from "react";
import { rpc } from "../lib/api";
import { fmt, STATUS_LABEL } from "../lib/labels";
import type { Status } from "../lib/types";
import { ErrorBox } from "../components/ui";
import { buildXlsx, downloadFile } from "../lib/xlsxWrite";

interface Row { request_id: string; request_no: string; submitted_at: string; department: string; applicant: string;
  line_no: number; product_code: string; product_name: string; revision: string | null; needed_date: string; is_urgent: boolean;
  status: Status; receipt_status: string; issued_by: string | null; issued_at: string | null; received_by: string | null; received_at: string | null }

const RECEIPT: Record<string, string> = { PENDING: "未簽收", RECEIVED: "已簽收", ABNORMAL: "異常" };
const today = () => new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);   // 台灣日期
const monthStart = () => today().slice(0, 8) + "01";
const HEAD = ["案件編號", "送出時間", "部門", "申請人", "項次", "產品編碼", "品名", "版次", "需求日期", "急件", "案件狀態", "簽收狀態", "發行人", "發行時間", "簽收人", "簽收時間"];
const cells = (r: Row) => [r.request_no, fmt(r.submitted_at), r.department, r.applicant, String(r.line_no), r.product_code, r.product_name,
  r.revision ?? "", r.needed_date, r.is_urgent ? "急件" : "", STATUS_LABEL[r.status] ?? r.status, RECEIPT[r.receipt_status] ?? r.receipt_status,
  r.issued_by ?? "", r.issued_at ? fmt(r.issued_at) : "", r.received_by ?? "", r.received_at ? fmt(r.received_at) : ""];

export default function DrawingReport() {
  const [from, setFrom] = useState(monthStart);
  const [to, setTo] = useState(today);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [range, setRange] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  async function search(e: FormEvent) {
    e.preventDefault(); setBusy(true); setError(null);
    try { setRows(await rpc<Row[]>("drawing_report", { p_from: from, p_to: to })); setRange(`${from} ～ ${to}`); }
    catch (err) { setError(err); setRows(null); } finally { setBusy(false); }
  }
  const excel = () => rows && downloadFile(`申請紀錄報表_${from}_${to}.xlsx`, buildXlsx("申請紀錄", [HEAD, ...rows.map(cells)]),
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

  return <section className="r8-card report">
    <h2>申請紀錄報表</h2>
    <form className="r8-toolbar no-print" onSubmit={search}>
      <label className="r8-row">送出日期 <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} required />
        ～ <input type="date" value={to} onChange={(e) => setTo(e.target.value)} required /></label>
      <div className="r8-actions" style={{ marginTop: 0 }}>
        <button className="r8-btn r8-primary" disabled={busy}>{busy ? "查詢中…" : "查詢"}</button>
        <button type="button" className="r8-btn" disabled={!rows?.length} onClick={() => window.print()}>列印／另存 PDF</button>
        <button type="button" className="r8-btn" disabled={!rows?.length} onClick={excel}>下載 Excel</button>
      </div>
    </form>
    <ErrorBox error={error} />
    {rows && <>
      <p className="r8-muted">送出日期 {range}｜共 {new Set(rows.map((r) => r.request_id)).size} 件、{rows.length} 筆圖面｜列印時間 {fmt(new Date().toISOString())}</p>
      {rows.length === 0 ? <p>此區間沒有申請紀錄。</p>
        : <div className="tablewrap"><table className="report-table">
          <thead><tr>{HEAD.map((h) => <th key={h}>{h}</th>)}</tr></thead>
          <tbody>{rows.map((r) => <tr key={r.request_id + r.line_no}>{cells(r).map((c, i) => <td key={i}>{c}</td>)}</tr>)}</tbody>
        </table></div>}
    </>}
  </section>;
}
