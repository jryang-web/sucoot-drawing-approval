import {useEffect,useState} from "react";
import {Link} from "react-router-dom";
import {rpc,query} from "../../lib/api";
import {supabase} from "../../lib/supabase";
import {fmt,STATUS_LABEL} from "../../lib/labels";
import type {Status} from "../../lib/types";
import {ErrorBox} from "../../components/ui";

interface Notice {id:number;request_id:string;read_at:string|null;occurred_at:string}
export default function ExceptionInbox(){
  const [rows,setRows]=useState<Notice[]>([]);
  const [cases,setCases]=useState<Record<string,{request_no:string;status:Status}>>({});
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    Promise.all([
      query<Notice[]>(supabase.from("exception_notices").select("*").order("id",{ascending:false})),
      query<{id:string;request_no:string;status:Status}[]>(supabase.from("v_requests").select("id,request_no,status"))
    ]).then(([notices,requests])=>{
      setRows(notices);setCases(Object.fromEntries(requests.map(r=>[r.id,r])));
    }).catch(setError);
  },[]);
  return <section className="r8-card"><h2>最近 30 天的整案異常通知</h2><ErrorBox error={error}/>
    {rows.length===0 && <p>目前沒有通知。</p>}
    {rows.map(n=><div className="r8-case-row" key={n.id}><span>{cases[n.request_id]?.request_no}｜{fmt(n.occurred_at)}｜{n.read_at?"已讀":"未讀"}｜{cases[n.request_id] && STATUS_LABEL[cases[n.request_id].status]}</span>
      <Link to={"/r/"+n.request_id} onClick={()=>{rpc("read_exception_notice",{p_id:n.id}).catch(setError)}}>查看案件</Link>
    </div>)}</section>;
}
