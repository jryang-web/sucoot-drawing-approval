import { useState } from "react";
import { rpc } from "../../../lib/api";
import { ACTION_LABEL, type SectionProps } from "../types";

type Action = "APPROVE" | "RETURN" | "REJECT";

/** 第一層（部門主管，可調降急件）／第二層（圖管主管）審核 */
export default function ReviewActions({ d, has, busy, run, level }: SectionProps & { level: 1 | 2 }) {
  const { r, items } = d;
  const [comment, setComment] = useState("");
  const [downgrade, setDowngrade] = useState(false);
  const [action,setAction] = useState<Action>("APPROVE");
  const status = level === 1 ? "PENDING_DEPT_REVIEW" : "PENDING_DRAWING_REVIEW";
  const role = level === 1 ? "DEPT_MANAGER" : "DRAWING_MANAGER";
  if (r.status !== status || !has(role)) return null;

  const submit = async (a: Action) => {
    if (!confirm("確定"+ACTION_LABEL[a]+"本案？")) return;
    const args: Record<string, unknown> = { p_id: r.id, p_action: a, p_comment: comment || null, p_expected_version: r.version };
    if (level === 1) {
      args.p_downgrades = downgrade && a === "APPROVE" ? items.filter(i=>i.is_urgent).map(i=>({item_id:i.id, reason:comment.trim()})) : [];
    }
    const ok = await run(() => rpc(level === 1 ? "review_level1" : "review_level2", args), `第${level === 1 ? "一" : "二"}層已${ACTION_LABEL[a]}`);
    if (ok) { setComment(""); setDowngrade(false); }
  };

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>第{level === 1 ? "一" : "二"}層審核</h2>
      <label>審核結果<select value={action} onChange={e=>setAction(e.target.value as Action)}>
        <option value="APPROVE">核准</option><option value="RETURN">退回補件</option><option value="REJECT">駁回</option>
      </select></label>
      {level===1 && action==="APPROVE" && items.some(i=>i.is_urgent) &&
        <label><input type="checkbox" checked={downgrade} onChange={e=>setDowngrade(e.target.checked)}/> 核准時將急件調降為一般件</label>}
      <label>原因／意見（退回、駁回、降急件必填）<textarea value={comment} onChange={e=>setComment(e.target.value)}/></label>
      <button className="r8-btn r8-primary" disabled={busy || ((action!=="APPROVE" || downgrade) && !comment.trim())}
        onClick={()=>submit(action)}>確認審核</button>
    </div>
  );
}
