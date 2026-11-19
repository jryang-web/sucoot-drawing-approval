import { fmt } from "../../../lib/labels";
import type { SectionProps } from "../types";

/** 異常與補發：圖管人員登記補發、負責人確認收到補發 */
export default function AbnormalSection({ d }: SectionProps) {
  const { items, abnormal } = d;
  if (!abnormal.length) return null;
  return (
    <div style={{ marginBottom: 12 }}>
      <h2>歷史逐筆異常與補發</h2>
      <div className="tablewrap"><table><thead><tr><th>產品編碼</th><th>原因</th><th>狀態</th><th></th></tr></thead><tbody>
        {abnormal.map((a) => (
          <tr key={a.id}>
            <td>{items.find((i) => i.id === a.item_id)?.drawing_no}</td>
            <td>{a.reason}<div className="muted">{fmt(a.reported_at)}</div></td>
            <td>{a.status === "OPEN" ? "待補發" : a.status === "REISSUED" ? `已補發 ${fmt(a.reissued_at)}` : `已確認 ${fmt(a.confirmed_at)}`}</td>
          </tr>))}
      </tbody></table></div>
    </div>
  );
}
