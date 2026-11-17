import { useState } from "react";
import { rpc } from "../../../lib/api";
import { activeClaim, type SectionProps } from "../types";

/** 圖管人員：整案認領、登記發行 */
export default function IssueActions({ d, me, has, busy, run, name }: SectionProps) {
  const { r } = d;
  const [lineNote, setLineNote] = useState("");
  if (r.status !== "PENDING_ISSUE" || !has("DRAWING_STAFF")) return null;
  const claim = activeClaim(d);

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>圖管發行</h2>
      {!claim && <button className="primary" disabled={busy}
        onClick={() => run(() => rpc("claim_issue", { p_id: r.id, p_expected_version: r.version }), "已認領")}>整案認領</button>}
      {claim?.staff_id === me.id && <>
        <p className="muted">請先將圖面上傳至 LINE 圖面申請群組，再登記發行完成。</p>
        <label>發行說明（例如 LINE 上傳時間、檔名）</label><input value={lineNote} onChange={(e) => setLineNote(e.target.value)} />
        <button className="primary" disabled={busy} onClick={async () => {
          if (await run(() => rpc("record_issue", { p_id: r.id, p_line_note: lineNote || null, p_expected_version: r.version }), "已登記發行")) setLineNote("");
        }}>登記發行完成</button>
      </>}
      {claim && claim.staff_id !== me.id && <p className="muted">已由 {name(claim.staff_id)} 認領</p>}
    </div>
  );
}
