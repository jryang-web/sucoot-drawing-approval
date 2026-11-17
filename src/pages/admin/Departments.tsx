import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { query, rpc } from "../../lib/api";
import type { Department } from "../../lib/types";
import { Card, ErrorBox, useAction } from "../../components/ui";

export default function Departments() {
  const [rows, setRows] = useState<Department[]>([]);
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const act = useAction();
  const { setError } = act;
  const load = useCallback(
    () => query<Department[]>(supabase.from("departments").select("*").order("code")).then(setRows).catch(setError),
    [setError],
  );
  useEffect(() => { load(); }, [load]);

  const save = (d: Partial<Department>, reason?: string) =>
    act.run(async () => { await rpc("admin_upsert_department", { p_id: d.id ?? null, p_code: d.code, p_name: d.name, p_is_active: d.is_active ?? true, p_reason: reason ?? null }); await load(); });

  return (
    <>
      <Card title="新增部門">
        <div className="grid2">
          <div><label>部門代碼（英數，建立後不可改）</label><input value={code} onChange={(e) => setCode(e.target.value)} /></div>
          <div><label>部門名稱</label><input value={name} onChange={(e) => setName(e.target.value)} /></div>
        </div>
        <button className="primary" style={{ marginTop: 8 }} disabled={act.busy || !code || !name}
          onClick={async () => { if (await save({ code, name })) { setCode(""); setName(""); } }}>新增</button>
      </Card>
      <Card title="部門清單">
        <ErrorBox error={act.error} />
        <div className="tablewrap"><table><thead><tr><th>代碼</th><th>名稱</th><th>狀態</th><th></th></tr></thead><tbody>
          {rows.map((d) => (
            <tr key={d.id}><td>{d.code}</td><td>{d.name}</td><td>{d.is_active ? "啟用" : <span className="badge">停用</span>}</td>
              <td className="row">
                <button onClick={() => { const n = prompt("新的部門名稱", d.name); if (n) save({ ...d, name: n }, "更名"); }}>更名</button>
                <button className={d.is_active ? "danger" : ""} onClick={() => {
                  const reason = prompt(d.is_active ? "停用原因" : "啟用原因"); if (reason) save({ ...d, is_active: !d.is_active }, reason);
                }}>{d.is_active ? "停用" : "啟用"}</button>
              </td></tr>))}
        </tbody></table></div>
      </Card>
    </>
  );
}
