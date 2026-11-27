import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useAuth } from "../../lib/auth";
import { ErrorBox, useAction } from "../../components/ui";
import { useRequestDetail } from "./useRequestDetail";
import type { SectionProps } from "./types";
import { fmt } from "../../lib/labels";
import MockLine from "../../components/MockLine";
import Summary from "./sections/Summary";
import ApplicantActions from "./sections/ApplicantActions";
import ReviewActions from "./sections/ReviewActions";
import IssueActions from "./sections/IssueActions";
import ReceiptActions from "./sections/ReceiptActions";
import AbnormalSection from "./sections/AbnormalSection";
import AdminActions from "./sections/AdminActions";
import HistorySection from "./sections/HistorySection";

/** 案件明細：資料由 useRequestDetail 載入，各角色可執行的操作拆在 sections/ */
export default function RequestDetail() {
  const { id } = useParams();
  const { me, has } = useAuth();
  const { data: d, error, reload } = useRequestDetail(id!);
  const act = useAction();
  const [msg, setMsg] = useState<string | null>(null);

  if (error) return <div className="card"><ErrorBox error={error} /><p className="muted">案件不存在或您沒有查看權限。</p></div>;
  if (!d || !me) return <p className="muted">載入中…</p>;

  const props: SectionProps = {
    d, me, has, busy: act.busy,
    name: (eid) => (eid && d.people[eid] ? `${d.people[eid].name}（${d.people[eid].employee_no}）` : "—"),
    run: async (fn, okMsg) => {
      setMsg(null);
      const ok = await act.run(fn);
      if (ok) { setMsg(okMsg); await reload(); }
      return ok;
    },
  };

  return (
    <>
      <div className="r8-toolbar"><Link to="/detail" className="r8-btn">← 返回案件列表</Link><span>{me.employee_no}｜{me.department_name}</span></div>
      <Summary {...props} />
      <section className="r8-card r8-work">
        {msg && <div className="okmsg">{msg}</div>}
        <ErrorBox error={act.error} />
        <ApplicantActions {...props} />
        <ReviewActions {...props} level={1} />
        <ReviewActions {...props} level={2} />
        <IssueActions {...props} />
        <ReceiptActions {...props} />
        <AbnormalSection {...props} />
        <AdminActions {...props} />
        {has("SYS_ADMIN") && d.exception && <section><h3>異常補充紀錄</h3>
          {d.notes.length===0 && <p>尚無補充紀錄。</p>}
          {d.notes.map(n=><div key={n.id}><b>{n.after.category}</b>｜{fmt(n.created_at)}｜{props.name(n.actor_id)}
            <p style={{whiteSpace:"pre-wrap"}}>{n.reason}</p></div>)}
        </section>}
      </section>
      <MockLine key={d.r.id+me.id} id={d.r.id} version={d.r.version}/>
      <details className="r8-card"><summary>審核與案件歷程</summary><HistorySection key={d.r.id} {...props} /></details>
    </>
  );
}
