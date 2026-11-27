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

// 各階段（依流程順序；草稿不列入報表）
const STAGES: Status[] = ["PENDING_DEPT_REVIEW", "PENDING_DRAWING_REVIEW", "RETURNED", "PENDING_ISSUE", "ISSUE_ABNORMAL",
  "PENDING_RECEIPT", "COMPLETED", "REJECTED", "CANCELLED"];
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
  const [stage, setStage] = useState<Status | "">("");
  const [dept, setDept] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  async function search(e: FormEvent) {
    e.preventDefault(); setBusy(true); setError(null);
    try {
      const data = await rpc<Row[]>("drawing_report", { p_from: from, p_to: to });
      setRows(data); setRange(`${from} ～ ${to}`);
      if (dept && !data.some((r) => r.department === dept)) setDept("");   // 新區間沒有該部門時回到全部
    }
    catch (err) { setError(err); setRows(null); } finally { setBusy(false); }
  }
  const departments = [...new Set((rows ?? []).map((r) => r.department))].sort((a, b) => a.localeCompare(b, "zh-Hant"));
  const shown = rows?.filter((r) => (!stage || r.status === stage) && (!dept || r.department === dept)) ?? null;
  const stageName = stage ? STATUS_LABEL[stage] : "全部";
  const excel = () => shown && downloadFile(`申請紀錄報表_${from}_${to}${dept ? "_" + dept : ""}${stage ? "_" + stageName : ""}.xlsx`, buildXlsx("申請紀錄", [HEAD, ...shown.map(cells)]),
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

  return <section className="r8-card report">
    <h2>申請紀錄報表</h2>
    <form className="r8-toolbar no-print" onSubmit={search}>
      <label className="r8-row">送出日期 <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} required />
        ～ <input type="date" value={to} onChange={(e) => setTo(e.target.value)} required /></label>
      <label className="r8-row">申請部門 <select value={dept} onChange={(e) => setDept(e.target.value)} aria-label="依申請部門篩選">
        <option value="">全部</option>{departments.map((d) => <option key={d} value={d}>{d}</option>)}</select></label>
      <label className="r8-row">階段 <select value={stage} onChange={(e) => setStage(e.target.value as Status | "")} aria-label="依階段篩選">
        <option value="">全部</option>{STAGES.map((st) => <option key={st} value={st}>{STATUS_LABEL[st]}</option>)}</select></label>
      <div className="r8-actions" style={{ marginTop: 0 }}>
        <button className="r8-btn r8-primary" disabled={busy}>{busy ? "查詢中…" : "查詢"}</button>
        <button type="button" className="r8-btn" disabled={!shown?.length} onClick={() => window.print()}>列印／另存 PDF</button>
        <button type="button" className="r8-btn" disabled={!shown?.length} onClick={excel}>下載 Excel</button>
      </div>
    </form>
    <ErrorBox error={error} />
    {shown && <>
      <p className="r8-muted">送出日期 {range}｜申請部門：{dept || "全部"}｜階段：{stageName}｜共 {new Set(shown.map((r) => r.request_id)).size} 件、{shown.length} 筆圖面｜列印時間 {fmt(new Date().toISOString())}</p>
      {shown.length === 0 ? <p>此條件沒有申請紀錄。</p>
        : <div className="tablewrap"><table className="report-table">
          <thead><tr>{HEAD.map((h) => <th key={h}>{h}</th>)}</tr></thead>
          <tbody>{shown.map((r) => <tr key={r.request_id + r.line_no}>{cells(r).map((c, i) => <td key={i}>{c}</td>)}</tr>)}</tbody>
        </table></div>}
    </>}
  </section>;
}
