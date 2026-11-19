import { useState } from "react";
import { rpc } from "../../../lib/api";
import { activeClaim, type SectionProps } from "../types";

/** 圖管人員：整案認領、登記發行 */
export default function IssueActions({ d, me, has, busy, run, name }: SectionProps) {
  const { r } = d;
  const [lineNote, setLineNote] = useState("");
  const [uploaded,setUploaded] = useState(false);
  if (r.status !== "PENDING_ISSUE" || !has("DRAWING_STAFF")) return null;
  const claim = activeClaim(d);

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>圖管發行</h2>
      {!claim && <button className="primary" disabled={busy}
        onClick={() => run(() => rpc("claim_issue", { p_id: r.id, p_expected_version: r.version }), "已認領")}>整案認領</button>}
      {claim?.staff_id === me.id && <>
        <p className="muted">請先將圖面上傳至 LINE 圖面申請群組，再登記發行完成。簽收期限為發行後第三個工作日，僅計週一至週五，發行當日不計。</p>
        <label>發行說明（例如 LINE 上傳時間、檔名）</label><input value={lineNote} onChange={(e) => setLineNote(e.target.value)} />
        <label><input type="checkbox" checked={uploaded} onChange={e=>setUploaded(e.target.checked)}/> 已確認全部圖面（本機模擬上傳）</label>
        <button className="primary" disabled={busy || !uploaded} onClick={async () => {
          if (!confirm("確認完成 APP 發行登記？")) return;
          if (await run(() => rpc("record_issue", { p_id: r.id, p_line_note: lineNote || null, p_expected_version: r.version }), "已登記發行")) setLineNote("");
        }}>登記發行完成</button>
      </>}
      {claim && claim.staff_id !== me.id && <p className="muted">已由 {name(claim.staff_id)} 認領</p>}
    </div>
  );
}
