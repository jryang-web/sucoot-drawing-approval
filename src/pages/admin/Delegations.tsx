import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { query, rpc } from "../../lib/api";
import type { Employee } from "../../lib/types";
import { Card, ErrorBox, useAction } from "../../components/ui";
import { fmt } from "../../lib/labels";

interface Delegation { id: string; principal_id: string; delegate_id: string; level: number; valid_from: string; valid_to: string; reason: string; revoked_at: string | null; created_at: string }

export default function Delegations() {
  const [rows, setRows] = useState<Delegation[]>([]);
  const [emps, setEmps] = useState<Employee[]>([]);
  const act = useAction();
  const { setError } = act;
  const load = useCallback(async () => {
    const [d, e] = await Promise.all([
      query<Delegation[]>(supabase.from("review_delegations").select("*").order("created_at", { ascending: false })),
      query<Employee[]>(supabase.from("employees").select("*").eq("is_active", true).order("employee_no")),
    ]);
    setRows(d); setEmps(e);
  }, []);
  useEffect(() => { load().catch(setError); }, [load, setError]);
  const name = (id: string) => { const e = emps.find((x) => x.id === id); return e ? `${e.name}（${e.employee_no}）` : id; };
  return (
    <>
      <ErrorBox error={act.error} />
      <Card title="代理紀錄">
        <p className="muted">代理由部門主管／圖管主管本人在「設定 &gt; 我的代理審核」建立；管理員可在此查看與撤銷。</p>
        <div className="tablewrap"><table><thead><tr><th>層級</th><th>被代理人</th><th>代理人</th><th>期間</th><th>原因</th><th>狀態</th></tr></thead><tbody>
          {rows.map((d) => (
            <tr key={d.id}><td>第 {d.level} 層</td><td>{name(d.principal_id)}</td><td>{name(d.delegate_id)}</td>
              <td>{d.valid_from} ～ {d.valid_to}</td><td>{d.reason}</td>
              <td>{d.revoked_at ? `已撤銷 ${fmt(d.revoked_at)}` : <button className="danger" onClick={() => {
                const reason = prompt("撤銷原因"); if (reason) act.run(async () => { await rpc("admin_revoke_delegation", { p_id: d.id, p_reason: reason }); await load(); });
              }}>撤銷</button>}</td></tr>))}
        </tbody></table></div>
      </Card>
    </>
  );
}
