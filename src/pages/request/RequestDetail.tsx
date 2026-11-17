import { useState } from "react";
import { useParams } from "react-router-dom";
import { useAuth } from "../../lib/auth";
import { Card, ErrorBox, useAction } from "../../components/ui";
import { useRequestDetail } from "./useRequestDetail";
import type { SectionProps } from "./types";
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
      <Summary {...props} />
      <Card title="操作">
        {msg && <div className="okmsg">{msg}</div>}
        <ErrorBox error={act.error} />
        <ApplicantActions {...props} />
        <ReviewActions {...props} level={1} />
        <ReviewActions {...props} level={2} />
        <IssueActions {...props} />
        <ReceiptActions {...props} />
        <AbnormalSection {...props} />
        <AdminActions {...props} />
      </Card>
      <HistorySection {...props} />
    </>
  );
}
