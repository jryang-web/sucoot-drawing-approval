import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { query } from "../lib/api";
import type { RequestRow, Status } from "../lib/types";
import { ErrorBox } from "../components/ui";
import { RequestList } from "./MyRequests";
import { STATUS_LABEL } from "../lib/labels";

const KINDS: Record<string, { title: string; statuses: Status[] }> = {
  l1: { title: "第一層待審（我管轄的部門）", statuses: ["PENDING_DEPT_REVIEW"] },
  l2: { title: "第二層待審", statuses: ["PENDING_DRAWING_REVIEW"] },
  issue: { title: "待發行／發行異常", statuses: ["PENDING_ISSUE", "ISSUE_ABNORMAL"] },
};

export default function Queue({ all, kind }: { all?: boolean; kind?: "l1" | "l2" | "issue" }) {
  const cfg = all || !kind ? null : KINDS[kind];
  const [params,setParams] = useSearchParams();
  const status = all ? params.get("status") ?? "" : "";
  const [rows, setRows] = useState<RequestRow[]>([]);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    const statuses = all || !kind ? null : KINDS[kind].statuses;
    let q = supabase.from(kind==="l1"?"v_l1_queue":kind==="l2"?"v_work_requests":"v_requests").select("*").order("updated_at", { ascending: false }).limit(200);
    if (kind==="l2") q=q.eq("approved_l1_by_me",false);
    if (statuses) q = q.in("status", statuses);
    else if (status === "OVERDUE") q = q.eq("is_receipt_overdue", true);
    else if (status) q = q.eq("status", status);
    query<RequestRow[]>(q).then(setRows).catch(setError);
  }, [kind, all, status]);

  return (
    <div className="card">
      <h1>{cfg ? cfg.title : "全部案件"}</h1>
      {!cfg && (
        <select value={status} onChange={(e) => setParams(e.target.value ? {status:e.target.value} : {})} style={{ maxWidth: 260, marginBottom: 12 }}>
          <option value="">全部狀態</option>
          <option value="OVERDUE">簽收逾期</option>
          {Object.entries(STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
      )}
      <ErrorBox error={error} />
      <RequestList rows={rows} />
    </div>
  );
}
