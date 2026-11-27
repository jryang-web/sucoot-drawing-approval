// 我的代理審核（部門主管／圖管主管）：本人建立自己的代理（後端 admin_create_delegation 限被代理人本人建立）
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { query, rpc } from "../lib/api";
import { useAuth } from "../lib/auth";
import type { DirectoryEntry } from "../lib/types";
import { fmt } from "../lib/labels";
import { ErrorBox, useAction } from "./ui";

interface Delegation { id: string; principal_id: string; delegate_id: string; level: number; valid_from: string; valid_to: string; reason: string; revoked_at: string | null }

const today = () => new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);   // 台灣日期

export function DelegationSettings() {
  const { me, has } = useAuth();
  const levels = [has("DEPT_MANAGER") && { v: 1, label: "第一層（部門主管）" }, has("DRAWING_MANAGER") && { v: 2, label: "第二層（圖管主管）" }]
    .filter(Boolean) as { v: number; label: string }[];
  const [people, setPeople] = useState<DirectoryEntry[]>([]);
  const [rows, setRows] = useState<Delegation[]>([]);
  const [level, setLevel] = useState(levels[0]?.v ?? 1);
  const [delegate, setDelegate] = useState("");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today);
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const act = useAction();
  const { setError } = act;
  const load = useCallback(async () => {
    const [p, d] = await Promise.all([
      query<DirectoryEntry[]>(supabase.from("v_employee_directory").select("*").eq("is_active", true).order("employee_no")),
      query<Delegation[]>(supabase.from("review_delegations").select("*").order("valid_from", { ascending: false })),
    ]);
    setPeople(p); setRows(d.map((x) => ({ ...x, valid_from: x.valid_from.slice(0, 10), valid_to: x.valid_to.slice(0, 10) })));
  }, []);
  useEffect(() => { if (levels.length) load().catch(setError); }, [levels.length, load, setError]);
  if (!me || !levels.length) return null;

  const name = (id: string) => { const e = people.find((x) => x.id === id); return e ? `${e.name}（${e.employee_no}）` : "—"; };
  const status = (d: Delegation) => d.revoked_at ? `已撤銷 ${fmt(d.revoked_at)}` : d.valid_to < today() ? "已到期" : d.valid_from > today() ? "尚未開始" : "生效中";
  async function submit(e: FormEvent) {
    e.preventDefault(); setMsg(null);
    if (!confirm(`確定設定 ${name(delegate)} 於 ${from} ～ ${to} 代理您的${level === 1 ? "第一層" : "第二層"}審核？`)) return;
    if (await act.run(async () => {
      await rpc("admin_create_delegation", { p_principal: me!.id, p_delegate: delegate, p_level: level, p_valid_from: from, p_valid_to: to, p_reason: reason.trim() });
      await load();
    })) { setMsg("已設定代理。"); setReason(""); setDelegate(""); }
  }
  const mine = rows.filter((d) => d.principal_id === me.id);
  const forMe = rows.filter((d) => d.delegate_id === me.id);

  return <section className="r8-card" aria-label="我的代理審核">
    <h2>我的代理審核</h2>
    <p className="r8-muted">休假或不在時，指定一位具相同審核角色的同事代理審核。起訖日合計須有 1～7 個工作日（週一至週五），開始日不可早於今天；同一期間只能設定一位代理人。</p>
    <form onSubmit={submit}>
      {levels.length > 1 && <><label>代理層級</label>
        <select value={level} onChange={(e) => setLevel(Number(e.target.value))}>{levels.map((l) => <option key={l.v} value={l.v}>{l.label}</option>)}</select></>}
      <label>代理人</label>
      <select value={delegate} onChange={(e) => setDelegate(e.target.value)} required>
        <option value="">請選擇</option>
        {people.filter((p) => p.id !== me.id).map((p) => <option key={p.id} value={p.id}>{p.name}（{p.employee_no}）</option>)}
      </select>
      <label>開始日</label><input type="date" value={from} min={today()} onChange={(e) => setFrom(e.target.value)} required />
      <label>結束日</label><input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} required />
      <label>代理原因（必填）</label><input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} required />
      <ErrorBox error={act.error} />
      {msg && <p role="status">{msg}</p>}
      <div className="r8-actions"><button className="r8-btn r8-primary" disabled={act.busy || !delegate || !reason.trim()}>設定代理</button></div>
    </form>
    <p className="r8-muted">代理人須具備相同審核角色，系統送出時會檢查。設定後無法自行修改；需要撤銷時請聯絡系統管理員。</p>
    {mine.length > 0 && <><h3>我設定的代理</h3>
      <div className="tablewrap"><table className="deleg-table"><thead><tr><th>層級</th><th>代理人</th><th>期間</th><th>原因</th><th>狀態</th></tr></thead><tbody>
        {mine.map((d) => <tr key={d.id}><td>第 {d.level} 層</td><td>{name(d.delegate_id)}</td><td>{d.valid_from} ～ {d.valid_to}</td><td>{d.reason}</td><td>{status(d)}</td></tr>)}
      </tbody></table></div></>}
    {forMe.length > 0 && <><h3>我被指定代理</h3>
      <div className="tablewrap"><table className="deleg-table"><thead><tr><th>層級</th><th>被代理人</th><th>期間</th><th>狀態</th></tr></thead><tbody>
        {forMe.map((d) => <tr key={d.id}><td>第 {d.level} 層</td><td>{name(d.principal_id)}</td><td>{d.valid_from} ～ {d.valid_to}</td><td>{status(d)}</td></tr>)}
      </tbody></table></div></>}
  </section>;
}
