import { useState } from "react";
import { rpc } from "../../../lib/api";
import { fmt } from "../../../lib/labels";
import type { SectionProps } from "../types";

/** 異常與補發：圖管人員登記補發、負責人確認收到補發 */
export default function AbnormalSection({ d, me, has, busy, run }: SectionProps) {
  const { r, items, abnormal } = d;
  const [lineNote, setLineNote] = useState("");
  if (abnormal.length === 0) return null;
  const isOwner = r.owner_id === me.id;
  const canReissue = r.status === "ISSUE_ABNORMAL" && has("DRAWING_STAFF");

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>異常與補發</h2>
      {canReissue && abnormal.some((a) => a.status === "OPEN") && <>
        <label>補發說明（選填）</label><input value={lineNote} onChange={(e) => setLineNote(e.target.value)} />
      </>}
      <div className="tablewrap"><table><thead><tr><th>產品編碼</th><th>原因</th><th>狀態</th><th></th></tr></thead><tbody>
        {abnormal.map((a) => (
          <tr key={a.id}>
            <td>{items.find((i) => i.id === a.item_id)?.drawing_no}</td>
            <td>{a.reason}<div className="muted">{fmt(a.reported_at)}</div></td>
            <td>{a.status === "OPEN" ? "待補發" : a.status === "REISSUED" ? `已補發 ${fmt(a.reissued_at)}` : `已確認 ${fmt(a.confirmed_at)}`}</td>
            <td>
              {a.status === "OPEN" && canReissue && <button disabled={busy} onClick={async () => {
                if (await run(() => rpc("reissue_item", { p_abnormal_id: a.id, p_line_note: lineNote || null }), "已登記補發")) setLineNote("");
              }}>登記補發</button>}
              {a.status === "REISSUED" && isOwner && <button className="primary" disabled={busy}
                onClick={() => run(() => rpc("confirm_reissued_item", { p_abnormal_id: a.id }), "已確認補發產品編碼")}>確認收到補發</button>}
            </td>
          </tr>))}
      </tbody></table></div>
    </div>
  );
}
