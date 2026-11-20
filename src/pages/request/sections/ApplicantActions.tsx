import { useState } from "react";
import { Link } from "react-router-dom";
import { rpc } from "../../../lib/api";
import type { SectionProps } from "../types";

/** 申請人：編輯、送出、退回後重送、取消（僅限原申請人且仍為負責人） */
export default function ApplicantActions({ d, me, busy, run }: SectionProps) {
  const { r } = d;
  const [note, setNote] = useState("");
  if (r.owner_id !== me.id || r.applicant_id !== me.id) return null;
  const st = r.status;
  const canCancel = ["DRAFT", "PENDING_DEPT_REVIEW", "RETURNED"].includes(st) && !d.reviews.some(x=>x.level===1 && x.action==="APPROVE");
  if (st !== "DRAFT" && st !== "RETURNED" && !canCancel) return null;

  return (
    <div style={{ marginBottom: 12 }}>
      {(st === "DRAFT" || st === "RETURNED") && (
        <div className="row" style={{ marginBottom: 8 }}>
          <Link to={`/r/${r.id}/edit`}><button>編輯內容</button></Link>
          {st === "DRAFT" && <button className="primary" disabled={busy}
            onClick={() => run(() => rpc("submit_request", { p_id: r.id, p_expected_version: r.version }), "已送出")}>送出申請</button>}
        </div>
      )}
      {st === "RETURNED" && (
        <div style={{ marginBottom: 8 }}>
          <p className="muted">第 {r.returned_level ?? "?"} 層退回。重新送出後一律從第一層重新審核；每次重送均須填寫回覆說明。</p>
          <label>回覆說明</label><textarea value={note} onChange={(e) => setNote(e.target.value)} />
          <button className="primary" disabled={busy || !note.trim()} onClick={async () => {
            if (await run(() => rpc("submit_request", { p_id: r.id, p_expected_version: r.version, p_resubmit_note: note }), "已重新送出")) setNote("");
          }}>重新送出</button>
        </div>
      )}
      {canCancel && (
        <button className="danger" disabled={busy} onClick={() => {
          const reason = prompt("取消原因（必填）");
          if (reason?.trim() && confirm("確定取消申請？")) run(() => rpc("cancel_request", { p_id: r.id, p_reason: reason, p_expected_version: r.version }), "已取消");
        }}>取消申請</button>
      )}
    </div>
  );
}
