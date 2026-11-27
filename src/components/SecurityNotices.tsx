import { useEffect, useState } from "react";
import { rpc } from "../lib/api";
import { fmt } from "../lib/labels";
import { ErrorBox } from "./ui";
import { requestBadgeRefresh } from "../lib/badge";

const titles = { initial: "首次密碼設定完成", change: "密碼已變更", reset: "管理員已重設您的密碼", activate: "您的帳號已重新啟用" };
interface Notice { id: string; event: keyof typeof titles; occurred_at: string; read_at: string | null }

export function SecurityNotices() {
  const [rows, setRows] = useState<Notice[]>();
  const [error, setError] = useState<unknown>();
  useEffect(() => {
    let active = true;
    rpc<Notice[]>("my_security_notices").then(result => {
      if (active) setRows(result);
    }).catch(e => { if (active) setError(e); });
    return () => { active = false; };
  }, []);
  async function markRead(id: string) {
    try {
      const seen = await rpc<string | null>("read_security_notice", { p_id: id });
      setRows(current => seen ? current?.map(n => n.id === id ? { ...n, read_at: seen } : n) : current?.filter(n => n.id !== id));
      setError(null);
      requestBadgeRefresh();   // V5.9.1：已讀後重新計算角標
    } catch (e) { setError(e); }
  }
  return <section className="r8-card"><h2>個人安全通知{rows && `（${rows.filter(n => !n.read_at).length} 未讀）`}</h2>
    <ErrorBox error={error}/>
    {rows?.length === 0 && <p>最近 30 天沒有安全通知。</p>}
    {rows?.map(n => <div className="r8-case-row" key={n.id}>
      <div><b>{titles[n.event]}</b> <span className="r8-pill">{n.read_at ? "已讀" : "未讀"}</span>
        <div className="r8-muted">{fmt(n.occurred_at)}</div></div>
      {!n.read_at && <button className="r8-btn" onClick={() => markRead(n.id)}>標為已讀</button>}
    </div>)}
  </section>;
}
