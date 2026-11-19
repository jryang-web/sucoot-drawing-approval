import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../lib/auth";
import { supabase } from "../../lib/supabase";
import { accountAction, query, rpc } from "../../lib/api";
import type { Department, Employee, Role } from "../../lib/types";
import { ALL_ROLES, ROLE_LABEL } from "../../lib/labels";
import { Card, ErrorBox, useAction } from "../../components/ui";

interface RoleRow { employee_id: string; role: Role }
interface MgrRow { manager_id: string; department_id: string }

function RolePicker({ value, onChange }: { value: Role[]; onChange: (r: Role[]) => void }) {
  return (
    <div className="row">
      {ALL_ROLES.filter((r) => r !== "EMPLOYEE").map((r) => (
        <label key={r} style={{ margin: 0, color: "inherit" }}>
          <input type="checkbox" checked={value.includes(r)} onChange={(e) => onChange(e.target.checked ? [...value, r] : value.filter((x) => x !== r))} />
          {ROLE_LABEL[r]}
        </label>))}
    </div>
  );
}

function DeptPicker({ depts, value, onChange }: { depts: Department[]; value: string[]; onChange: (d: string[]) => void }) {
  return (
    <div className="row">
      {depts.filter((d) => d.is_active).map((d) => (
        <label key={d.id} style={{ margin: 0, color: "inherit" }}>
          <input type="checkbox" checked={value.includes(d.id)} onChange={(e) => onChange(e.target.checked ? [...value, d.id] : value.filter((x) => x !== d.id))} />
          {d.name}
        </label>))}
    </div>
  );
}

export default function Employees() {
  const {me}=useAuth();
  const [emps, setEmps] = useState<Employee[]>([]);
  const [depts, setDepts] = useState<Department[]>([]);
  const [roles, setRoles] = useState<RoleRow[]>([]);
  const [mgr, setMgr] = useState<MgrRow[]>([]);
  const [secret, setSecret] = useState<{ who: string; pw: string } | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [form, setForm] = useState({ employee_no: "", name: "", department_id: "", roles: [] as Role[], mgr: [] as string[] });
  const [edit, setEdit] = useState({ name: "", department_id: "", roles: [] as Role[], mgr: [] as string[], reason: "" });
  const act = useAction();

  const { setError } = act;
  const load = useCallback(async () => {
    const [e, d, r, m] = await Promise.all([
      query<Employee[]>(supabase.from("employees").select("*").order("employee_no")),
      query<Department[]>(supabase.from("departments").select("*").order("code")),
      query<RoleRow[]>(supabase.from("employee_roles").select("employee_id,role")),
      query<MgrRow[]>(supabase.from("manager_departments").select("manager_id,department_id")),
    ]);
    setEmps(e); setDepts(d); setRoles(r); setMgr(m);
  }, []);
  useEffect(() => { load().catch(setError); }, [load, setError]);

  const rolesOf = (id: string) => roles.filter((r) => r.employee_id === id).map((r) => r.role);
  const mgrOf = (id: string) => mgr.filter((m) => m.manager_id === id).map((m) => m.department_id);
  const deptName = (id: string) => depts.find((d) => d.id === id)?.name ?? "—";

  const create = () => act.run(async () => {
    const res = await accountAction<{ initial_password: string; employee_no: string }>({
      action: "create_account", employee_no: form.employee_no, name: form.name, department_id: form.department_id,
      roles: form.roles, manager_department_ids: form.roles.includes("DEPT_MANAGER") ? form.mgr : [],
    });
    setSecret({ who: res.employee_no, pw: res.initial_password });
    setForm({ employee_no: "", name: "", department_id: "", roles: [], mgr: [] });
    await load();
  });

  const startEdit = (e: Employee) => {
    setEditing(e.id);
    setEdit({ name: e.name, department_id: e.department_id, roles: rolesOf(e.id).filter((r) => r !== "EMPLOYEE"), mgr: mgrOf(e.id), reason: "" });
  };
  const saveEdit = (e: Employee) => act.run(async () => {
    const reason = edit.reason || null;
    if (edit.name !== e.name || edit.department_id !== e.department_id)
      await rpc("admin_update_employee", { p_employee_id: e.id, p_name: edit.name, p_department_id: edit.department_id, p_reason: reason });
    await rpc("admin_set_roles", { p_employee_id: e.id, p_roles: edit.roles, p_reason: reason });
    await rpc("admin_set_manager_departments", { p_manager_id: e.id, p_department_ids: edit.roles.includes("DEPT_MANAGER") ? edit.mgr : [], p_reason: reason });
    setEditing(null); await load();
  });

  return (
    <>
      {secret && (
        <Card title="初始密碼（只顯示這一次）">
          <p>員工 <strong>{secret.who}</strong> 的密碼：</p>
          <div className="secret">{secret.pw}</div>
          <p className="muted">請以安全方式交給本人（當面或私訊），不要貼到群組。員工首次登入時必須修改密碼。關閉後無法再查看。</p>
          <button onClick={() => setSecret(null)}>我已記下，關閉</button>
        </Card>
      )}

      <Card title="建立員工帳號">
        <div className="grid2">
          <div><label>員工編號（英數，2–32 碼，登入用，建立後不可改）</label><input value={form.employee_no} onChange={(e) => setForm({ ...form, employee_no: e.target.value })} autoCapitalize="none" /></div>
          <div><label>姓名</label><input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></div>
          <div><label>部門</label>
            <select value={form.department_id} onChange={(e) => setForm({ ...form, department_id: e.target.value })}>
              <option value="">請選擇</option>{depts.filter((d) => d.is_active).map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
            </select></div>
        </div>
        <label>角色（一般員工權限一律具備）</label>
        <RolePicker value={form.roles} onChange={(r) => setForm({ ...form, roles: r })} />
        {form.roles.includes("DEPT_MANAGER") && <><label>管轄部門</label><DeptPicker depts={depts} value={form.mgr} onChange={(m) => setForm({ ...form, mgr: m })} /></>}
        <button className="primary" style={{ marginTop: 12 }} disabled={act.busy || !form.employee_no || !form.name || !form.department_id} onClick={create}>建立帳號</button>
        <p className="muted">系統會產生 16 碼初始密碼並只顯示一次。</p>
      </Card>

      <Card title={`員工清單（${emps.length}）`}>
        <ErrorBox error={act.error} />
        <div className="tablewrap"><table>
          <thead><tr><th>編號</th><th>姓名</th><th>部門</th><th>角色／管轄</th><th>狀態</th><th></th></tr></thead>
          <tbody>{emps.map((e) => editing === e.id ? (
            <tr key={e.id}><td colSpan={6}>
              <strong>{e.employee_no}</strong>
              <div className="grid2">
                <div><label>姓名</label><input value={edit.name} onChange={(x) => setEdit({ ...edit, name: x.target.value })} /></div>
                <div><label>部門</label><select value={edit.department_id} onChange={(x) => setEdit({ ...edit, department_id: x.target.value })}>
                  {depts.filter((d) => d.is_active || d.id === edit.department_id).map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></div>
              </div>
              <label>角色</label><RolePicker value={edit.roles} onChange={(r) => setEdit({ ...edit, roles: r })} />
              {edit.roles.includes("DEPT_MANAGER") && <><label>管轄部門</label><DeptPicker depts={depts} value={edit.mgr} onChange={(m) => setEdit({ ...edit, mgr: m })} /></>}
              <label>變更原因</label><input value={edit.reason} onChange={(x) => setEdit({ ...edit, reason: x.target.value })} />
              <div className="row" style={{ marginTop: 8 }}>
                <button className="primary" disabled={act.busy} onClick={() => saveEdit(e)}>儲存</button>
                <button onClick={() => setEditing(null)}>取消</button>
              </div>
            </td></tr>
          ) : (
            <tr key={e.id}>
              <td>{e.employee_no}</td><td>{e.name}</td><td>{deptName(e.department_id)}</td>
              <td>{rolesOf(e.id).filter((r) => r !== "EMPLOYEE").map((r) => ROLE_LABEL[r]).join("、") || "一般員工"}
                {mgrOf(e.id).length > 0 && <div className="muted">管轄：{mgrOf(e.id).map(deptName).join("、")}</div>}</td>
              <td>{e.is_active ? "啟用" : <span className="badge danger">停用</span>}{e.must_change_password && e.is_active && <div className="muted">待改密碼</div>}</td>
              <td className="row">
                <button onClick={() => startEdit(e)}>編輯</button>
                <button disabled={me?.id===e.id} onClick={() => {
                  const reason = prompt(`重設 ${e.employee_no} 的密碼，原因：`);
                  if (reason) act.run(async () => {
                    const res = await accountAction<{ new_password: string }>({ action: "reset_password", employee_id: e.id, reason });
                    setSecret({ who: e.employee_no, pw: res.new_password }); await load();
                  });
                }}>重設密碼</button>
                <button className={e.is_active ? "danger" : ""} onClick={() => {
                  const reason = prompt(`${e.is_active ? "停用" : "啟用"} ${e.employee_no}，原因：`);
                  if (reason) act.run(async () => { await accountAction({ action: "set_active", employee_id: e.id, active: !e.is_active, reason }); await load(); });
                }}>{e.is_active ? "停用" : "啟用"}</button>
              </td>
            </tr>))}
          </tbody>
        </table></div>
      </Card>
    </>
  );
}
