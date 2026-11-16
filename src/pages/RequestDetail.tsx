import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { query, rpc } from "../lib/api";
import { useAuth } from "../lib/auth";
import type { Employee, Item, RequestRow } from "../lib/types";
import { fmt, STATUS_LABEL } from "../lib/labels";
import { Card, ErrorBox, StatusBadge, useAction } from "../components/ui";

interface Review { id: string; round: number; level: number; action: string; reviewer_id: string; on_behalf_of_id: string | null; comment: string | null; is_effective: boolean; created_at: string }
interface History { id: number; from_status: string | null; to_status: string; actor_id: string | null; reason: string | null; created_at: string }
interface Claim { id: string; staff_id: string; claimed_at: string; released_at: string | null; release_reason: string | null; reassigned_to: string | null }
interface Abnormal { id: string; item_id: string; reason: string; status: "OPEN" | "REISSUED" | "CONFIRMED"; reported_at: string; reissued_at: string | null; confirmed_at: string | null }
interface Transfer { id: string; from_owner_id: string; to_owner_id: string; reason: string; created_at: string }
interface Revision { round: number; resubmit_note: string | null; submitted_at: string }

const ACTION_LABEL: Record<string, string> = { APPROVE: "核准", RETURN: "退回", REJECT: "拒絕" };

export default function RequestDetail() {
  const { id } = useParams();
  const { me, has } = useAuth();
  const [r, setR] = useState<RequestRow | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [history, setHistory] = useState<History[]>([]);
  const [claims, setClaims] = useState<Claim[]>([]);
  const [abn, setAbn] = useState<Abnormal[]>([]);
  const [transfers, setTransfers] = useState<Transfer[]>([]);
  const [revisions, setRevisions] = useState<Revision[]>([]);
  const [emps, setEmps] = useState<Record<string, Employee>>({});
  const [loadErr, setLoadErr] = useState<unknown>(null);
  const [comment, setComment] = useState("");
  const [lineNote, setLineNote] = useState("");
  const [downgrades, setDowngrades] = useState<Record<string, string>>({});
  const [abnSel, setAbnSel] = useState<Record<string, string>>({});
  const [target, setTarget] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const act = useAction();

  const load = useCallback(async () => {
    try {
      const row = await query<RequestRow>(supabase.from("v_requests").select("*").eq("id", id!).single());
      const [its, rv, hs, cl, ab, tr, rs, es] = await Promise.all([
        query<Item[]>(supabase.from("drawing_request_items").select("*").eq("request_id", id!).order("line_no")),
        query<Review[]>(supabase.from("review_records").select("*").eq("request_id", id!).order("created_at")),
        query<History[]>(supabase.from("request_status_history").select("*").eq("request_id", id!).order("id")),
        query<Claim[]>(supabase.from("issue_claims").select("*").eq("request_id", id!).order("claimed_at")),
        query<Abnormal[]>(supabase.from("item_abnormal_reports").select("*").eq("request_id", id!).order("reported_at")),
        query<Transfer[]>(supabase.from("ownership_transfers").select("*").eq("request_id", id!).order("created_at")),
        query<Revision[]>(supabase.from("request_revisions").select("round,resubmit_note,submitted_at").eq("request_id", id!).order("round")),
        query<Employee[]>(supabase.from("employees").select("*")),
      ]);
      setR(row); setItems(its); setReviews(rv); setHistory(hs); setClaims(cl); setAbn(ab); setTransfers(tr); setRevisions(rs);
      setEmps(Object.fromEntries(es.map((e) => [e.id, e])));
      setLoadErr(null);
    } catch (e) { setLoadErr(e); }
  }, [id]);
  useEffect(() => { load(); }, [load]);

  if (loadErr) return <div className="card"><ErrorBox error={loadErr} /><p className="muted">案件不存在或您沒有查看權限。</p></div>;
  if (!r || !me) return <p className="muted">載入中…</p>;

  const name = (eid: string | null | undefined) => (eid && emps[eid] ? `${emps[eid].name}（${emps[eid].employee_no}）` : "—");
  const doIt = async (fn: () => Promise<unknown>, okMsg: string) => {
    setMsg(null);
    if (await act.run(fn)) { setMsg(okMsg); setComment(""); setLineNote(""); setDowngrades({}); setAbnSel({}); setTarget(""); await load(); }
  };
  const v = r.version;
  const isOwner = r.owner_id === me.id;
  const isApplicantOwner = isOwner && r.applicant_id === me.id;
  const activeClaim = claims.find((c) => !c.released_at);
  const st = r.status;
  const activeEmps = Object.values(emps).filter((e) => e.is_active);

  return (
    <>
      <Card title={r.request_no} right={<StatusBadge status={st} overdue={r.is_receipt_overdue} />}>
        <div className="grid2">
          <div><label>原申請人</label>{r.applicant_name}（{r.applicant_no}）</div>
          <div><label>目前負責人</label>{r.owner_name}（{r.owner_no}）</div>
          <div><label>部門</label>{r.department_name}</div>
          <div><label>送審輪次</label>{r.round || "—"}</div>
          <div><label>發行時間</label>{fmt(r.issued_at)}</div>
          <div><label>簽收期限</label>{r.receipt_due_date ?? "—"}{r.is_receipt_overdue && <span className="badge danger" style={{ marginLeft: 6 }}>逾期</span>}</div>
          {activeClaim && <div><label>認領人</label>{name(activeClaim.staff_id)}</div>}
        </div>
        {r.note && <><label>整案備註</label><div>{r.note}</div></>}
      </Card>

      <Card title={`圖號明細（${items.length} 筆）`}>
        <div className="tablewrap"><table>
          <thead><tr><th>#</th><th>圖號／圖名</th><th>版次</th><th>用途</th><th>需求日</th><th>急件</th><th>簽收</th></tr></thead>
          <tbody>{items.map((it) => (
            <tr key={it.id}>
              <td>{it.line_no}</td>
              <td><strong>{it.drawing_no}</strong><br />{it.drawing_name}{it.remark && <div className="muted">{it.remark}</div>}</td>
              <td>{it.revision ?? "—"}</td><td>{it.purpose}</td><td>{it.needed_date}</td>
              <td>{it.is_urgent ? <span className="badge warn" title={it.urgency_reason ?? ""}>急件</span> : it.downgrade_reason ? <span className="muted">已調降：{it.downgrade_reason}</span> : "—"}</td>
              <td>{it.receipt_status === "RECEIVED" ? "已收" : it.receipt_status === "ABNORMAL" ? <span className="badge danger">異常</span> : "—"}</td>
            </tr>))}
          </tbody>
        </table></div>
      </Card>

      {/* ---------------- 可執行的動作 ---------------- */}
      <Card title="操作">
        {msg && <div className="okmsg">{msg}</div>}
        <ErrorBox error={act.error} />

        {isApplicantOwner && (st === "DRAFT" || st === "RETURNED") && (
          <div className="row" style={{ marginBottom: 8 }}>
            <Link to={`/r/${r.id}/edit`}><button>編輯內容</button></Link>
            {st === "DRAFT" && <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("submit_request", { p_id: r.id, p_expected_version: v }), "已送出")}>送出申請</button>}
          </div>
        )}
        {isApplicantOwner && st === "RETURNED" && (
          <div style={{ marginBottom: 8 }}>
            <p className="muted">第 {r.returned_level ?? "?"} 層退回。重新送出後一律從第一層重新審核；內容未修改時必須填寫回覆說明。</p>
            <label>回覆說明</label><textarea value={comment} onChange={(e) => setComment(e.target.value)} />
            <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("submit_request", { p_id: r.id, p_expected_version: v, p_resubmit_note: comment }), "已重新送出")}>重新送出</button>
          </div>
        )}
        {isApplicantOwner && ["DRAFT", "PENDING_DEPT_REVIEW", "RETURNED"].includes(st) && (
          <button className="danger" disabled={act.busy} onClick={() => {
            const reason = prompt("取消原因（選填）") ?? undefined;
            if (reason !== undefined) doIt(() => rpc("cancel_request", { p_id: r.id, p_reason: reason, p_expected_version: v }), "已取消");
          }}>取消申請</button>
        )}

        {st === "PENDING_DEPT_REVIEW" && has("DEPT_MANAGER") && (
          <div>
            <h2>第一層審核</h2>
            {items.filter((i) => i.is_urgent).map((i) => (
              <div key={i.id}><label>調降急件 {i.drawing_no}（填寫原因即調降）</label>
                <input value={downgrades[i.id] ?? ""} onChange={(e) => setDowngrades({ ...downgrades, [i.id]: e.target.value })} /></div>
            ))}
            <label>審核意見（退回／拒絕必填）</label><textarea value={comment} onChange={(e) => setComment(e.target.value)} />
            <ReviewButtons busy={act.busy} onAct={(a) => doIt(() => rpc("review_level1", {
              p_id: r.id, p_action: a, p_comment: comment || null, p_expected_version: v,
              p_downgrades: Object.entries(downgrades).filter(([, x]) => x.trim()).map(([item_id, reason]) => ({ item_id, reason })),
            }), `第一層已${ACTION_LABEL[a]}`)} />
          </div>
        )}

        {st === "PENDING_DRAWING_REVIEW" && has("DRAWING_MANAGER") && (
          <div>
            <h2>第二層審核</h2>
            <label>審核意見（退回／拒絕必填）</label><textarea value={comment} onChange={(e) => setComment(e.target.value)} />
            <ReviewButtons busy={act.busy} onAct={(a) => doIt(() => rpc("review_level2", { p_id: r.id, p_action: a, p_comment: comment || null, p_expected_version: v }), `第二層已${ACTION_LABEL[a]}`)} />
          </div>
        )}

        {st === "PENDING_ISSUE" && has("DRAWING_STAFF") && (
          <div>
            <h2>圖管發行</h2>
            {!activeClaim && <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("claim_issue", { p_id: r.id, p_expected_version: v }), "已認領")}>整案認領</button>}
            {activeClaim?.staff_id === me.id && <>
              <p className="muted">請先將圖面上傳至 LINE 圖面申請群組，再登記發行完成。</p>
              <label>發行說明（例如 LINE 上傳時間、檔名）</label><input value={lineNote} onChange={(e) => setLineNote(e.target.value)} />
              <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("record_issue", { p_id: r.id, p_line_note: lineNote || null, p_expected_version: v }), "已登記發行")}>登記發行完成</button>
            </>}
            {activeClaim && activeClaim.staff_id !== me.id && <p className="muted">已由 {name(activeClaim.staff_id)} 認領</p>}
          </div>
        )}

        {isOwner && (st === "PENDING_RECEIPT" || st === "ISSUE_ABNORMAL") && (
          <div>
            <h2>簽收</h2>
            {st === "PENDING_RECEIPT" && <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("confirm_receipt", { p_id: r.id, p_expected_version: v }), "已完成簽收")}>確認整案收到</button>}
            <h2 style={{ marginTop: 12 }}>回報個別圖號異常</h2>
            {items.filter((i) => i.receipt_status !== "ABNORMAL").map((i) => (
              <div key={i.id}><label>{i.drawing_no} 異常原因（填寫即回報）</label>
                <input value={abnSel[i.id] ?? ""} onChange={(e) => setAbnSel({ ...abnSel, [i.id]: e.target.value })} /></div>
            ))}
            <button className="danger" disabled={act.busy || !Object.values(abnSel).some((x) => x.trim())} onClick={() => doIt(() => rpc("report_abnormal", {
              p_id: r.id, p_expected_version: v,
              p_items: Object.entries(abnSel).filter(([, x]) => x.trim()).map(([item_id, reason]) => ({ item_id, reason })),
            }), "已回報異常")}>回報異常</button>
          </div>
        )}

        {abn.length > 0 && (
          <div>
            <h2 style={{ marginTop: 12 }}>異常與補發</h2>
            <div className="tablewrap"><table><thead><tr><th>圖號</th><th>原因</th><th>狀態</th><th></th></tr></thead><tbody>
              {abn.map((a) => {
                const it = items.find((i) => i.id === a.item_id);
                return (
                  <tr key={a.id}>
                    <td>{it?.drawing_no}</td><td>{a.reason}<div className="muted">{fmt(a.reported_at)}</div></td>
                    <td>{a.status === "OPEN" ? "待補發" : a.status === "REISSUED" ? `已補發 ${fmt(a.reissued_at)}` : `已確認 ${fmt(a.confirmed_at)}`}</td>
                    <td>
                      {a.status === "OPEN" && st === "ISSUE_ABNORMAL" && has("DRAWING_STAFF") &&
                        <button disabled={act.busy} onClick={() => doIt(() => rpc("reissue_item", { p_abnormal_id: a.id, p_line_note: lineNote || null }), "已登記補發")}>登記補發</button>}
                      {a.status === "REISSUED" && isOwner &&
                        <button className="primary" disabled={act.busy} onClick={() => doIt(() => rpc("confirm_reissued_item", { p_abnormal_id: a.id }), "已確認補發圖號")}>確認收到補發</button>}
                    </td>
                  </tr>);
              })}
            </tbody></table></div>
          </div>
        )}

        {has("SYS_ADMIN") && (
          <div style={{ borderTop: "1px solid var(--line)", marginTop: 16, paddingTop: 8 }}>
            <h2>管理員例外處理</h2>
            <p className="muted">所有操作都會留下稽核紀錄；管理員不可代為審核、發行或簽收。</p>
            <label>原因（必填）</label><input value={comment} onChange={(e) => setComment(e.target.value)} />
            {st === "PENDING_ISSUE" && activeClaim && <>
              <label>重新指派給圖管人員（留空＝只解除認領）</label>
              <select value={target} onChange={(e) => setTarget(e.target.value)}>
                <option value="">（只解除認領）</option>
                {activeEmps.filter((e) => e.id !== activeClaim.staff_id).map((e) => <option key={e.id} value={e.id}>{e.name}（{e.employee_no}）</option>)}
              </select>
              <button disabled={act.busy} onClick={() => doIt(() => rpc("admin_release_claim", { p_id: r.id, p_reason: comment, p_reassign_to: target || null }), "已更新認領")}>解除認領／重新指派</button>
            </>}
            {!["COMPLETED", "REJECTED", "CANCELLED"].includes(st) && <>
              <label>移交簽收負責人</label>
              <select value={target} onChange={(e) => setTarget(e.target.value)}>
                <option value="">請選擇新負責人</option>
                {activeEmps.filter((e) => e.id !== r.owner_id).map((e) => <option key={e.id} value={e.id}>{e.name}（{e.employee_no}）</option>)}
              </select>
              <button disabled={act.busy || !target} onClick={() => doIt(() => rpc("admin_transfer_owner", { p_id: r.id, p_to: target, p_reason: comment }), "已移交")}>移交</button>
            </>}
          </div>
        )}
      </Card>

      <Card title="審核紀錄">
        {reviews.length === 0 ? <p className="muted">尚無</p> : (
          <div className="tablewrap"><table><thead><tr><th>輪次</th><th>層級</th><th>結果</th><th>審核者</th><th>意見</th><th>時間</th></tr></thead><tbody>
            {reviews.map((x) => (
              <tr key={x.id} style={{ opacity: x.is_effective ? 1 : 0.55 }}>
                <td>{x.round}</td><td>第 {x.level} 層</td>
                <td>{ACTION_LABEL[x.action]}{!x.is_effective && <div className="muted">（已失效）</div>}</td>
                <td>{name(x.reviewer_id)}{x.on_behalf_of_id && <div className="muted">代理 {name(x.on_behalf_of_id)}</div>}</td>
                <td>{x.comment ?? "—"}</td><td>{fmt(x.created_at)}</td>
              </tr>))}
          </tbody></table></div>)}
        {revisions.some((x) => x.resubmit_note) && <>
          <h2 style={{ marginTop: 12 }}>重送回覆說明</h2>
          {revisions.filter((x) => x.resubmit_note).map((x) => <div key={x.round} className="muted">第 {x.round} 輪：{x.resubmit_note}</div>)}
        </>}
      </Card>

      <Card title="狀態歷程">
        <div className="tablewrap"><table><tbody>
          {history.map((h) => (
            <tr key={h.id}><td>{fmt(h.created_at)}</td>
              <td>{h.from_status ? STATUS_LABEL[h.from_status as keyof typeof STATUS_LABEL] : "—"} → <strong>{STATUS_LABEL[h.to_status as keyof typeof STATUS_LABEL]}</strong></td>
              <td>{name(h.actor_id)}</td><td>{h.reason}</td></tr>))}
          {claims.map((c) => (
            <tr key={c.id}><td>{fmt(c.claimed_at)}</td><td>認領</td><td>{name(c.staff_id)}</td>
              <td>{c.released_at ? `已解除（${c.release_reason}）${c.reassigned_to ? `→ ${name(c.reassigned_to)}` : ""}` : "認領中"}</td></tr>))}
          {transfers.map((t) => (
            <tr key={t.id}><td>{fmt(t.created_at)}</td><td>負責人移交</td><td>{name(t.from_owner_id)} → {name(t.to_owner_id)}</td><td>{t.reason}</td></tr>))}
        </tbody></table></div>
      </Card>
    </>
  );
}

function ReviewButtons({ busy, onAct }: { busy: boolean; onAct: (a: "APPROVE" | "RETURN" | "REJECT") => void }) {
  return (
    <div className="row" style={{ marginTop: 8 }}>
      <button className="primary" disabled={busy} onClick={() => onAct("APPROVE")}>核准</button>
      <button disabled={busy} onClick={() => onAct("RETURN")}>退回</button>
      <button className="danger" disabled={busy} onClick={() => confirm("確定拒絕？拒絕後案件即結束。") && onAct("REJECT")}>拒絕</button>
    </div>
  );
}
