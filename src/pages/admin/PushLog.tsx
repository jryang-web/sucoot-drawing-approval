// V5.9.1：推播發送紀錄（系統管理員唯讀）。不顯示裝置 endpoint、金鑰或通知內容。
import { useEffect, useState } from "react";
import { rpc } from "../../lib/api";
import { Card, ErrorBox } from "../../components/ui";
import { fmt } from "../../lib/labels";

interface Row { id: number; employee: string; request_no: string; kind: string; status: string; attempts: number;
  accepted: number; failed: number; last_error: string | null; created_at: string; sent_at: string | null }
interface Summary { subscriptions: { active: number; revoked: number }; outbox: Record<string, number>; enqueue_errors: number; recent: Row[] }

const KIND: Record<string, string> = { L1: "第一層待審", L2: "第二層待審", ISSUE: "圖面待發行", RETURNED: "退回補件", RECEIPT: "待簽收", ABNORMAL: "整案異常",
  R_REJECTED: "申請已駁回", R_FORCE_CLOSED: "案件已結案", R_CANCELLED: "申請已取消", R_RECEIPT_DONE: "已完成簽收" };
const STATUS: Record<string, string> = { PENDING: "等待發送／重試", SENDING: "發送中", SENT: "推播服務已接受", FAILED: "失敗", SKIPPED: "略過" };
const ERROR: Record<string, string> = { NO_SUBSCRIPTION: "收件人未啟用通知", NOT_ELIGIBLE: "發送前已不是此類待辦（已被他人處理、類別已改變或帳號停用）",
  DISPATCH_INTERRUPTED: "發送程式中斷超過 5 次" };

export default function PushLog() {
  const [data, setData] = useState<Summary | null>(null);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { rpc<Summary>("admin_push_summary", { p_limit: 100 }).then(setData).catch(setError); }, []);
  return (
    <Card title="推播發送紀錄">
      <p className="muted">「推播服務已接受」代表 Apple／Google 等推播服務已收下，不代表手機已收到或角標已更新。</p>
      <ErrorBox error={error} />
      {data && <>
        <div className="r8-metrics">
          <div className="r8-meter"><strong>{data.subscriptions.active}</strong>已啟用通知的裝置</div>
          {Object.entries(STATUS).map(([k, label]) => <div className="r8-meter" key={k}><strong>{data.outbox[k] ?? 0}</strong>{label}</div>)}
          <div className="r8-meter"><strong>{data.enqueue_errors}</strong>排入佇列失敗</div>
        </div>
        <div className="tablewrap"><table>
          <thead><tr><th>時間</th><th>收件人</th><th>案件</th><th>類別</th><th>狀態</th><th>嘗試</th><th>說明</th></tr></thead>
          <tbody>{data.recent.map((r) => <tr key={r.id}>
            <td>{fmt(r.created_at)}</td><td>{r.employee}</td><td>{r.request_no}</td><td>{KIND[r.kind] ?? r.kind}</td>
            <td>{STATUS[r.status] ?? r.status}</td><td>{r.attempts}</td>
            <td>{r.last_error ? (ERROR[r.last_error] ?? r.last_error) : r.sent_at ? `接受 ${r.accepted}／失敗 ${r.failed}` : ""}</td>
          </tr>)}</tbody>
        </table></div>
        {data.recent.length === 0 && <p>目前沒有推播紀錄。</p>}
      </>}
    </Card>
  );
}
