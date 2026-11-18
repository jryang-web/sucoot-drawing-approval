import { StatusBadge } from "../../../components/ui";
import { fmt } from "../../../lib/labels";
import type { SectionProps } from "../types";

export default function Summary({ d }: SectionProps) {
  const {r,items}=d;
  return <>
    <section className="r8-card"><h2>{r.request_no} <StatusBadge status={r.status} overdue={r.is_receipt_overdue}/></h2>
      <div className="r8-kv">
        <div><small>申請人／部門</small><b>{r.applicant_name}／{r.department_name}</b></div>
        <div><small>首次正式申請日期</small><b>{fmt(d.revisions[0]?.submitted_at ?? null)}</b></div>
        <div><small>整案用途</small><b>{Array.from(new Set(items.map(i=>i.purpose))).join("、")}</b></div>
        <div><small>優先順序</small><b>{items.some(i=>i.is_urgent)?"急件":"一般件"}</b></div>
      </div>{r.note && <p>{r.note}</p>}
      <details><summary>案件資料</summary><p>目前負責人：{r.owner_name}（{r.owner_no}）｜送審輪次：{r.round}</p><p>發行時間：{fmt(r.issued_at)}｜簽收期限：{r.receipt_due_date??"—"}</p></details>
    </section>
    <section className="r8-card"><h2>產品明細（{items.length} 筆）</h2>{items.map(i=><div className="r8-case-row" key={i.id}><b>{i.line_no}. {i.drawing_no}</b><span>{i.drawing_name} {i.revision} {i.remark} {i.needed_date}</span></div>)}</section>
  </>;
}
