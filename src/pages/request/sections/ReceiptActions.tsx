import { useState } from "react";
import { rpc } from "../../../lib/api";
import type { SectionProps } from "../types";

/** 案件負責人：整案簽收、回報個別產品編碼異常 */
export default function ReceiptActions({ d, me, busy, run }: SectionProps) {
  const { r, items } = d;
  const [reasons, setReasons] = useState<Record<string, string>>({});
  if (r.owner_id !== me.id || (r.status !== "PENDING_RECEIPT" && r.status !== "ISSUE_ABNORMAL")) return null;
  const selected = Object.entries(reasons).filter(([, x]) => x.trim());

  return (
    <div style={{ marginBottom: 12 }}>
      <h2>簽收</h2>
      {r.status === "PENDING_RECEIPT" && <button className="primary" disabled={busy}
        onClick={() => run(() => rpc("confirm_receipt", { p_id: r.id, p_expected_version: r.version }), "已完成簽收")}>確認整案收到</button>}
      <h2 style={{ marginTop: 12 }}>回報個別產品編碼異常</h2>
      {items.filter((i) => i.receipt_status !== "ABNORMAL").map((i) => (
        <div key={i.id}><label>{i.drawing_no} 異常原因（填寫即回報）</label>
          <input value={reasons[i.id] ?? ""} onChange={(e) => setReasons({ ...reasons, [i.id]: e.target.value })} /></div>
      ))}
      <button className="danger" disabled={busy || selected.length === 0} onClick={async () => {
        const ok = await run(() => rpc("report_abnormal", {
          p_id: r.id, p_expected_version: r.version,
          p_items: selected.map(([item_id, reason]) => ({ item_id, reason })),
        }), "已回報異常");
        if (ok) setReasons({});
      }}>回報異常</button>
    </div>
  );
}
