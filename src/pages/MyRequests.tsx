import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { query } from "../lib/api";
import { useAuth } from "../lib/auth";
import type { RequestRow } from "../lib/types";
import { ErrorBox, StatusBadge } from "../components/ui";
import { fmt } from "../lib/labels";

export function RequestList({ rows }: { rows: RequestRow[] }) {
  if (!rows.length) return <p className="muted">沒有案件</p>;
  return (
    <div className="list">
      {rows.map((r) => (
        <Link key={r.id} to={`/r/${r.id}`} className="item">
          <div className="row" style={{ justifyContent: "space-between" }}>
            <strong>{r.request_no}</strong>
            <StatusBadge status={r.status} overdue={r.is_receipt_overdue} />
          </div>
          <div className="muted">
            {r.applicant_name}（{r.department_name}）· {r.item_count} 筆產品編碼{r.is_urgent ? " · 急件" : ""}
            {r.owner_id !== r.applicant_id && ` · 負責人：${r.owner_name}`}
          </div>
          <div className="muted">更新：{fmt(r.updated_at)}{r.receipt_due_date && ` · 簽收期限：${r.receipt_due_date}`}</div>
        </Link>
      ))}
    </div>
  );
}

export default function MyRequests() {
  const { me } = useAuth();
  const [rows, setRows] = useState<RequestRow[]>([]);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => {
    query<RequestRow[]>(supabase.from("v_requests").select("*")
      .or(`applicant_id.eq.${me!.id},owner_id.eq.${me!.id}`).order("updated_at", { ascending: false }))
      .then(setRows).catch(setError);
  }, [me]);
  return (
    <div className="card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>我的案件</h1><Link to="/new"><button className="primary">＋ 新增申請</button></Link>
      </div>
      <ErrorBox error={error} />
      <RequestList rows={rows} />
    </div>
  );
}
