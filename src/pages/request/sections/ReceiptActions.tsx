import { useState } from "react";
import { rpc } from "../../../lib/api";
import type { SectionProps } from "../types";

/** 案件負責人：整案簽收、回報個別產品編碼異常 */
export default function ReceiptActions({ d, me, busy, run }: SectionProps) {
  const { r, exception } = d;
  const [reason,setReason] = useState("");
  if ((r.owner_id !== me.id && r.applicant_id !== me.id) || (r.status !== "PENDING_RECEIPT" && r.status !== "ISSUE_ABNORMAL")) return null;
  const withdraw = r.status === "ISSUE_ABNORMAL";
  const canReport = r.applicant_id === me.id && (withdraw ? exception && !exception.withdrawal_reason : !exception);
  return (
    <div style={{ marginBottom: 12 }}>
      <h2>簽收</h2>
      {r.owner_id === me.id && r.status === "PENDING_RECEIPT" && <button className="primary" disabled={busy}
        onClick={() => confirm("第一次確認：全部產品圖面均已收到？") && confirm("第二次確認：結案後永久唯讀。確定？") && run(() => rpc("confirm_receipt", { p_id: r.id, p_expected_version: r.version }), "已完成簽收")}>確認整案收到</button>}
      {exception && <p>整案異常：{exception.reason}{exception.withdrawal_reason && "（已撤回："+exception.withdrawal_reason+"）"}</p>}
      {canReport && <><label>{withdraw?"撤回原因":"整案異常原因"}（必填）
        <textarea value={reason} onChange={e=>setReason(e.target.value)}/></label>
        <button disabled={busy || !reason.trim()} onClick={async()=>{
          if (!confirm(withdraw?"撤回後無法再次提出異常，確定？":"每案限一次，送出後無法修改。確定？")) return;
          if(await run(()=>rpc("case_exception",{p_id:r.id,p_reason:reason,p_withdraw:withdraw,p_expected_version:r.version}),withdraw?"已撤回":"已提出整案異常")) setReason("");
        }}>{withdraw?"撤回整案異常":"提出整案異常"}</button></>}
    </div>
  );
}
