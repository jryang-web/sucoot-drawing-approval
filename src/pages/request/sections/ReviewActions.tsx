import { useState } from "react";
import { rpc } from "../../../lib/api";
import { ACTION_LABEL, type SectionProps } from "../types";

type Action = "APPROVE" | "RETURN" | "REJECT";

/** 第一層（部門主管，可調降急件）／第二層（圖管主管）審核 */
export default function ReviewActions({ d, has, busy, run, level }: SectionProps & { level: 1 | 2 }) {
  const { r, items } = d;
  const [comment, setComment] = useState("");
  const [downgrades, setDowngrades] = useState<Record<string, string>>({});
  const status = level === 1 ? "PENDING_DEPT_REVIEW" : "PENDING_DRAWING_REVIEW";
  const role = level === 1 ? "DEPT_MANAGER" : "DRAWING_MANAGER";
  if (r.status !== status || !has(role)) return null;

  const submit = async (a: Action) => {
    const args: Record<string, unknown> = { p_id: r.id, p_action: a, p_comment: comment || null, p_expected_version: r.version };
    if (level === 1) {
      args.p_downgrades = Object.entries(downgrades).filter(([, x]) => x.trim()).map(([item_id, reason]) => ({ item_id, reason }));
    }
    const ok = await run(() => rpc(level === 1 ? "review_level1" : "review_level2", args), `第${level === 1 ? "一" : "二"}層已${ACTION_LABEL[a]}`);
    if (ok) { setComment(""); setDowngrades({}); }
  };

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>第{level === 1 ? "一" : "二"}層審核</h2>
      {level === 1 && items.filter((i) => i.is_urgent).map((i) => (
        <div key={i.id}><label>調降急件 {i.drawing_no}（填寫原因即調降）</label>
          <input value={downgrades[i.id] ?? ""} onChange={(e) => setDowngrades({ ...downgrades, [i.id]: e.target.value })} /></div>
      ))}
      <label>審核意見（退回／拒絕必填）</label><textarea value={comment} onChange={(e) => setComment(e.target.value)} />
      <div className="row" style={{ marginTop: 8 }}>
        <button className="primary" disabled={busy} onClick={() => submit("APPROVE")}>核准</button>
        <button disabled={busy} onClick={() => submit("RETURN")}>退回</button>
        <button className="danger" disabled={busy} onClick={() => confirm("確定拒絕？拒絕後案件即結束。") && submit("REJECT")}>拒絕</button>
      </div>
    </div>
  );
}
