// V5.9.2：案件通知（駁回、強制結案、取消、簽收完成）。已讀／未讀、最近 30 天；標為已讀後重新計算角標。
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { rpc } from "../lib/api";
import { fmt } from "../lib/labels";
import { ErrorBox } from "./ui";
import { badgeRefreshEvent, requestBadgeRefresh } from "../lib/badge";

const titles: Record<string, string> = {
  R_REJECTED: "申請已駁回", R_FORCE_CLOSED: "案件已由管理員結案", R_CANCELLED: "申請已取消（無需審核）", R_RECEIPT_DONE: "已完成簽收",
};
interface Notice { id: number; kind: string; request_id: string; request_no: string; occurred_at: string; read_at: string | null }

export function CaseNotices() {
  const [rows, setRows] = useState<Notice[]>();
  const [error, setError] = useState<unknown>();
  useEffect(() => {
    let active = true;
    const load = () => rpc<Notice[]>("my_case_notices").then((r) => { if (active) { setRows(r); setError(null); } })
      .catch((e) => { if (active) setError(e); });
    void load();
    // 收到推播或其他同步時一併更新列表
    window.addEventListener(badgeRefreshEvent, load);
    return () => { active = false; window.removeEventListener(badgeRefreshEvent, load); };
  }, []);
  async function markRead(id: number) {
    try {
      const seen = await rpc<string | null>("read_case_notice", { p_id: id });
      setRows((cur) => (seen ? cur?.map((n) => (n.id === id ? { ...n, read_at: seen } : n)) : cur?.filter((n) => n.id !== id)));
      setError(null);
      requestBadgeRefresh();
    } catch (e) { setError(e); }
  }
  return <section className="r8-card" aria-label="案件通知">
    <h2>案件通知{rows && `（${rows.filter((n) => !n.read_at).length} 未讀）`}</h2>
    <ErrorBox error={error}/>
    {rows?.length === 0 && <p>最近 30 天沒有案件通知。</p>}
    {rows?.map((n) => <div className="r8-case-row" key={n.id}>
      <div><b>{titles[n.kind] ?? "案件通知"}</b> <span className="r8-pill">{n.read_at ? "已讀" : "未讀"}</span>
        <div className="r8-muted">{n.request_no}｜{fmt(n.occurred_at)}</div></div>
      <div>
        <Link className="r8-btn" to={"/r/" + n.request_id}>查看案件</Link>
        {!n.read_at && <button className="r8-btn" onClick={() => markRead(n.id)}>標為已讀</button>}
      </div>
    </div>)}
  </section>;
}
