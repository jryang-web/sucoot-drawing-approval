import { useEffect, useState } from "react";
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
  const [status, setStatus] = useState<string>("");
  const [rows, setRows] = useState<RequestRow[]>([]);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    let q = supabase.from("v_requests").select("*").order("updated_at", { ascending: false }).limit(200);
    if (cfg) q = q.in("status", cfg.statuses);
    else if (status === "OVERDUE") q = q.eq("is_receipt_overdue", true);
    else if (status) q = q.eq("status", status);
    query<RequestRow[]>(q).then(setRows).catch(setError);
  }, [kind, all, status]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="card">
      <h1>{cfg ? cfg.title : "全部案件"}</h1>
      {!cfg && (
        <select value={status} onChange={(e) => setStatus(e.target.value)} style={{ maxWidth: 260, marginBottom: 12 }}>
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
