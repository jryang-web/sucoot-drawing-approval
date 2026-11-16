import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { query } from "../../lib/api";
import type { Employee } from "../../lib/types";
import { Card, ErrorBox } from "../../components/ui";
import { fmt } from "../../lib/labels";

interface Log { id: number; actor_id: string | null; action: string; target_type: string; target_id: string | null; before: unknown; after: unknown; reason: string | null; created_at: string }

export default function Audit() {
  const [rows, setRows] = useState<Log[]>([]);
  const [emps, setEmps] = useState<Record<string, Employee>>({});
  const [error, setError] = useState<unknown>(null);
  useEffect(() => {
    Promise.all([
      query<Log[]>(supabase.from("admin_audit_logs").select("*").order("id", { ascending: false }).limit(300)),
      query<Employee[]>(supabase.from("employees").select("*")),
    ]).then(([l, e]) => { setRows(l); setEmps(Object.fromEntries(e.map((x) => [x.id, x]))); }).catch(setError);
  }, []);
  return (
    <Card title="管理員稽核紀錄（最新 300 筆）">
      <ErrorBox error={error} />
      <div className="tablewrap"><table><thead><tr><th>時間</th><th>操作者</th><th>動作</th><th>對象</th><th>原因</th><th>內容</th></tr></thead><tbody>
        {rows.map((l) => (
          <tr key={l.id}><td>{fmt(l.created_at)}</td><td>{l.actor_id ? emps[l.actor_id]?.employee_no ?? l.actor_id : "—"}</td>
            <td>{l.action}</td><td>{l.target_type}{l.target_type === "employee" && l.target_id && emps[l.target_id] ? `：${emps[l.target_id].employee_no}` : ""}</td>
            <td>{l.reason ?? "—"}</td>
            <td><details><summary>查看</summary><pre style={{ whiteSpace: "pre-wrap", fontSize: 12 }}>{JSON.stringify({ before: l.before, after: l.after }, null, 2)}</pre></details></td></tr>))}
      </tbody></table></div>
    </Card>
  );
}
