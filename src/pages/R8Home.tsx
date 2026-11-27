import { SecurityNotices } from "../components/SecurityNotices";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { query, rpc } from "../lib/api";
import { supabase } from "../lib/supabase";
import { STATUS_LABEL } from "../lib/labels";
import type { RequestRow } from "../lib/types";
import { ErrorBox } from "../components/ui";
import { NotificationSettings } from "../components/NotificationSettings";
import { CaseNotices } from "../components/CaseNotices";
import { requestBadgeRefresh } from "../lib/badge";

type WorkRequest = RequestRow & { approved_l1_by_me: boolean };

export default function R8Home() {
  const {me, has} = useAuth();
  const [rows, setRows] = useState<WorkRequest[]>([]);
  const [departments,setDepartments] = useState<string[]>([]);
  const [error, setError] = useState<unknown>();
  useEffect(() => { requestBadgeRefresh(); }, []);   // V5.9.1：切換到工作首頁時同步角標
  useEffect(() => {
    let current=true;
    async function load() {
      const requests: WorkRequest[]=[];
      const pageSize=500;
      for (;;) {
        const batch=await query<WorkRequest[]>(supabase.from("v_work_requests").select("*")
          .order("updated_at",{ascending:false}).order("id").range(requests.length,requests.length+pageSize-1));
        requests.push(...batch);
        if(batch.length<pageSize)break;
      }
      const managed=me?.roles.includes("DEPT_MANAGER") ? await rpc<string[]>("my_l1_departments") : [];
      if(current){setRows(requests);setDepartments(managed);setError(null);}
    }
    load().catch(e=>{if(current)setError(e)});
    return ()=>{current=false};
  },[me]);
  if (!me) return null;
  const groups = [
    {label:"退回補件", show:has("EMPLOYEE"), rows:rows.filter(r=>r.status==="RETURNED" && r.applicant_id===me.id && r.owner_id===me.id)},
    {label:"第一層待審", show:has("DEPT_MANAGER"), rows:rows.filter(r=>r.status==="PENDING_DEPT_REVIEW" && departments.includes(r.department_id))},
    {label:"第二層待審", show:has("DRAWING_MANAGER"), rows:rows.filter(r=>r.status==="PENDING_DRAWING_REVIEW" && !r.approved_l1_by_me && r.applicant_id!==me.id)},
    {label:"圖面待發行", show:has("DRAWING_STAFF"), rows:rows.filter(r=>r.status==="PENDING_ISSUE" && (!r.claimed_by || r.claimed_by===me.id))},
    {label:"整案異常待辦", show:has("SYS_ADMIN"), rows:rows.filter(r=>r.status==="ISSUE_ABNORMAL")},
    {label:"待簽收", show:has("EMPLOYEE"), rows:rows.filter(r=>r.status==="PENDING_RECEIPT" && r.owner_id===me.id)}
  ].filter(g=>g.show);
  const tasks=[...new Map(groups.flatMap(g=>g.rows).map(r=>[r.id,r])).values()];   // 同一案件只列一次
  const row=(r:RequestRow)=><div className="r8-case-row" key={r.id}><div><b>{r.request_no}</b> <span className="r8-pill">{STATUS_LABEL[r.status]}</span><div className="r8-muted">{r.department_name}｜{r.item_count} 筆｜{r.is_urgent?"急件":"一般件"}</div></div><Link className="r8-btn" to={'/r/'+r.id}>查看案件</Link></div>;
  return <><ErrorBox error={error}/><section className="r8-card"><h2>我的工作</h2><div className="r8-metrics">{[{label:"我的案件",rows:rows.filter(r=>r.applicant_id===me.id)},...groups].map(g=><div className="r8-meter" key={g.label}><strong>{g.rows.length}</strong>{g.label}</div>)}</div></section>
    <section className="r8-card"><h2>目前待辦（{tasks.length}）</h2>{tasks.length?tasks.map(row):"目前沒有待辦。"}</section>
    <NotificationSettings key={"n"+me.id}/>
    <CaseNotices key={"c"+me.id}/>
    <SecurityNotices key={me.id}/>
    <section className="r8-card"><h2>案件查詢與權限可視化</h2>{rows.map(row)}</section></>;
}
