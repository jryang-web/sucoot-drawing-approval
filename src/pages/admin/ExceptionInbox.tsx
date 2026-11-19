import {useEffect,useState} from "react";
import {Link} from "react-router-dom";
import {rpc,query} from "../../lib/api";
import {supabase} from "../../lib/supabase";
import {fmt,STATUS_LABEL} from "../../lib/labels";
import type {Status} from "../../lib/types";
import {ErrorBox} from "../../components/ui";

interface Notice {id:number;request_id:string;read_at:string|null;occurred_at:string;case_exceptions:{reason:string;withdrawn_at:string|null;withdrawal_reason:string|null}|null}
export default function ExceptionInbox(){
  const [rows,setRows]=useState<Notice[]>([]);
  const [cases,setCases]=useState<Record<string,{request_no:string;status:Status}>>({});
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    Promise.all([
      query<Notice[]>(supabase.from("exception_notices").select("id,request_id,read_at,occurred_at,case_exceptions(reason,withdrawn_at,withdrawal_reason)").order("id",{ascending:false}).returns<Notice[]>()),
      query<{id:string;request_no:string;status:Status}[]>(supabase.from("v_requests").select("id,request_no,status"))
    ]).then(([notices,requests])=>{
      setRows(notices);setCases(Object.fromEntries(requests.map(r=>[r.id,r])));
    }).catch(setError);
  },[]);
  return <section className="r8-card"><h2>最近 30 天的整案異常通知</h2><ErrorBox error={error}/>
    {rows.length===0 && <p>目前沒有通知。</p>}
    {rows.map(n=><div className="r8-case-row" key={n.id}><span>{cases[n.request_id]?.request_no}｜{fmt(n.occurred_at)}｜{n.read_at?"已讀":"未讀"}｜{cases[n.request_id] && STATUS_LABEL[cases[n.request_id].status]}
        {n.case_exceptions && <><br/>回報原因：{n.case_exceptions.reason}</>}
        {n.case_exceptions?.withdrawn_at && <><br/><strong className="r8-pill">已撤回</strong> {fmt(n.case_exceptions.withdrawn_at)}｜{n.case_exceptions.withdrawal_reason}</>}</span>
      <Link to={"/r/"+n.request_id} onClick={()=>{rpc("read_exception_notice",{p_id:n.id}).catch(setError)}}>查看案件</Link>
    </div>)}</section>;
}
