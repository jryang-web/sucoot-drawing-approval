import { Card, StatusBadge } from "../../../components/ui";
import { fmt } from "../../../lib/labels";
import { activeClaim, type SectionProps } from "../types";

/** 案件基本資料與圖號明細 */
export default function Summary({ d, name }: SectionProps) {
  const { r, items } = d;
  const claim = activeClaim(d);
  return (
    <>
      <Card title={r.request_no} right={<StatusBadge status={r.status} overdue={r.is_receipt_overdue} />}>
        <div className="grid2">
          <div><label>原申請人</label>{r.applicant_name}（{r.applicant_no}）</div>
          <div><label>目前負責人</label>{r.owner_name}（{r.owner_no}）</div>
          <div><label>部門</label>{r.department_name}</div>
          <div><label>送審輪次</label>{r.round || "—"}</div>
          <div><label>發行時間</label>{fmt(r.issued_at)}</div>
          <div><label>簽收期限</label>{r.receipt_due_date ?? "—"}{r.is_receipt_overdue && <span className="badge danger" style={{ marginLeft: 6 }}>逾期</span>}</div>
          {claim && <div><label>認領人</label>{name(claim.staff_id)}</div>}
        </div>
        {r.note && <><label>整案備註</label><div>{r.note}</div></>}
      </Card>

      <Card title={`圖號明細（${items.length} 筆）`}>
        <div className="tablewrap"><table>
          <thead><tr><th>#</th><th>圖號／圖名</th><th>版次</th><th>用途</th><th>需求日</th><th>急件</th><th>簽收</th></tr></thead>
          <tbody>{items.map((it) => (
            <tr key={it.id}>
              <td>{it.line_no}</td>
              <td><strong>{it.drawing_no}</strong><br />{it.drawing_name}{it.remark && <div className="muted">{it.remark}</div>}</td>
              <td>{it.revision ?? "—"}</td><td>{it.purpose}</td><td>{it.needed_date}</td>
              <td>{it.is_urgent ? <span className="badge warn" title={it.urgency_reason ?? ""}>急件</span>
                : it.downgrade_reason ? <span className="muted">已調降：{it.downgrade_reason}</span> : "—"}</td>
              <td>{it.receipt_status === "RECEIVED" ? "已收" : it.receipt_status === "ABNORMAL" ? <span className="badge danger">異常</span> : "—"}</td>
            </tr>))}
          </tbody>
        </table></div>
      </Card>
    </>
  );
}
