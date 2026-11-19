import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";
import { query, rpc } from "../../../lib/api";
import { activeClaim, type SectionProps } from "../types";

const CLOSED = ["COMPLETED", "REJECTED", "CANCELLED"];

/** 系統管理員例外處理：解除認領／重新指派（E04）、移交簽收負責人（E06）。不可代為審核、發行或簽收 */
export default function AdminActions({ d, has, busy, run }: SectionProps) {
  const { r, people } = d;
  const isAdmin = has("SYS_ADMIN");
  const [reason, setReason] = useState("");
  const [reassignTo, setReassignTo] = useState("");
  const [category, setCategory] = useState("");
  const [staffIds, setStaffIds] = useState<string[]>([]);
  const claim = activeClaim(d);
  const showReassign = r.status === "PENDING_ISSUE" && !!claim;

  // 重新指派只列出圖管人員（管理員可讀角色資料）
  useEffect(() => {
    if (!isAdmin || !showReassign) return;
    query<{ employee_id: string }[]>(supabase.from("employee_roles").select("employee_id").eq("role", "DRAWING_STAFF"))
      .then((rows) => setStaffIds(rows.map((x) => x.employee_id))).catch(() => setStaffIds([]));
  }, [isAdmin, showReassign]);

  if (!isAdmin || (!showReassign && CLOSED.includes(r.status))) return null;
  const active = Object.values(people).filter((p) => p.is_active);
  const done = () => { setReason(""); setReassignTo(""); setCategory(""); };

  return (
    <div style={{ borderTop: "1px solid var(--line)", marginTop: 16, paddingTop: 8 }}>
      <h2>管理員例外處理</h2>
      <p className="muted">所有操作都會留下稽核紀錄；管理員不可代為審核、發行或簽收。</p>
      <label>原因（必填）</label><input value={reason} onChange={(e) => setReason(e.target.value)} />

      {showReassign && <>
        <label>重新指派給圖管人員（留空＝只解除認領）</label>
        <select value={reassignTo} onChange={(e) => setReassignTo(e.target.value)}>
          <option value="">（只解除認領）</option>
          {active.filter((p) => staffIds.includes(p.id) && p.id !== claim!.staff_id)
            .map((p) => <option key={p.id} value={p.id}>{p.name}（{p.employee_no}）</option>)}
        </select>
        <button disabled={busy} onClick={async () => {
          if (await run(() => rpc("admin_release_claim", { p_id: r.id, p_reason: reason, p_reassign_to: reassignTo || null }), "已更新認領")) done();
        }}>解除認領／重新指派</button>
      </>}

      {r.status !== "DRAFT" && <>
        <label>強制結案原因分類<select value={category} onChange={e=>setCategory(e.target.value)}>
          <option value="">請選擇</option>{["人員離職","簽收異常","案件無法繼續處理","其他"].map(c=><option key={c}>{c}</option>)}
        </select></label>
        <button disabled={busy || !category || !reason.trim()} onClick={async()=>{
          if (!confirm("確定終止本案所有未完成待辦？") || !confirm("強制結案後永久唯讀，確定？")) return;
          if (await run(()=>rpc("admin_force_close",{p_id:r.id,p_category:category,p_reason:reason,p_expected_version:r.version}),"已強制結案")) done();
        }}>強制結案</button>
      </>}
    </div>
  );
}
