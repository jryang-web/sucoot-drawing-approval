import { Card } from "../../../components/ui";
import { fmt, STATUS_LABEL } from "../../../lib/labels";
import type { Status } from "../../../lib/types";
import { ACTION_LABEL, type SectionProps } from "../types";

/** 審核紀錄、重送說明、狀態歷程（含認領與移交） */
export default function HistorySection({ d, name }: SectionProps) {
  const { reviews, revisions, history, claims, transfers } = d;
  return (
    <>
      <Card title="審核紀錄">
        {reviews.length === 0 ? <p className="muted">尚無</p> : (
          <div className="tablewrap"><table><thead><tr><th>輪次</th><th>層級</th><th>結果</th><th>審核者</th><th>意見</th><th>時間</th></tr></thead><tbody>
            {reviews.map((x) => (
              <tr key={x.id} style={{ opacity: x.is_effective ? 1 : 0.55 }}>
                <td>{x.round}</td><td>第 {x.level} 層</td>
                <td>{ACTION_LABEL[x.action]}{!x.is_effective && <div className="muted">（已失效）</div>}</td>
                <td>{name(x.reviewer_id)}{x.on_behalf_of_id && <div className="muted">代理 {name(x.on_behalf_of_id)}</div>}</td>
                <td>{x.comment ?? "—"}</td><td>{fmt(x.created_at)}</td>
              </tr>))}
          </tbody></table></div>)}
        {revisions.some((x) => x.resubmit_note) && <>
          <h2 style={{ marginTop: 12 }}>重送回覆說明</h2>
          {revisions.filter((x) => x.resubmit_note).map((x) => <div key={x.round} className="muted">第 {x.round} 輪：{x.resubmit_note}</div>)}
        </>}
      </Card>

      <Card title="狀態歷程">
        <div className="tablewrap"><table><tbody>
          {history.map((h) => (
            <tr key={h.id}><td>{fmt(h.created_at)}</td>
              <td>{h.from_status ? STATUS_LABEL[h.from_status as Status] : "—"} → <strong>{STATUS_LABEL[h.to_status as Status]}</strong></td>
              <td>{name(h.actor_id)}</td><td>{h.reason}</td></tr>))}
          {claims.map((c) => (
            <tr key={c.id}><td>{fmt(c.claimed_at)}</td><td>認領</td><td>{name(c.staff_id)}</td>
              <td>{c.released_at ? `已解除（${c.release_reason}）${c.reassigned_to ? `→ ${name(c.reassigned_to)}` : ""}` : "認領中"}</td></tr>))}
          {transfers.map((t) => (
            <tr key={t.id}><td>{fmt(t.created_at)}</td><td>負責人移交</td><td>{name(t.from_owner_id)} → {name(t.to_owner_id)}</td><td>{t.reason}</td></tr>))}
        </tbody></table></div>
      </Card>
    </>
  );
}
