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
  const today = new Date().toLocaleDateString("sv-SE", { timeZone: "Asia/Taipei" });
  const [f, setF] = useState({ principal: "", delegate: "", level: "1", from: today, to: today, reason: "" });
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
  const empSelect = (v: string, on: (v: string) => void) => (
    <select value={v} onChange={(e) => on(e.target.value)}><option value="">請選擇</option>
      {emps.map((e) => <option key={e.id} value={e.id}>{e.name}（{e.employee_no}）</option>)}</select>);

  return (
    <>
      <Card title="指定代理審核人">
        <p className="muted">代理人須具備相同審核角色；期間最長 30 天；代理人仍受「兩層審核者不得相同」限制。</p>
        <div className="grid2">
          <div><label>被代理人（原審核者）</label>{empSelect(f.principal, (v) => setF({ ...f, principal: v }))}</div>
          <div><label>代理人</label>{empSelect(f.delegate, (v) => setF({ ...f, delegate: v }))}</div>
          <div><label>審核層級</label><select value={f.level} onChange={(e) => setF({ ...f, level: e.target.value })}>
            <option value="1">第一層（部門主管）</option><option value="2">第二層（圖管主管）</option></select></div>
          <div><label>原因</label><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></div>
          <div><label>開始日</label><input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></div>
          <div><label>結束日</label><input type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></div>
        </div>
        <ErrorBox error={act.error} />
        <button className="primary" style={{ marginTop: 8 }} disabled={act.busy} onClick={() => act.run(async () => {
          await rpc("admin_create_delegation", { p_principal: f.principal, p_delegate: f.delegate, p_level: Number(f.level), p_valid_from: f.from, p_valid_to: f.to, p_reason: f.reason });
          await load();
        })}>建立代理</button>
      </Card>
      <Card title="代理紀錄">
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
