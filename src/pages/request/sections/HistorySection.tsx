import { useEffect, useState } from "react";
import { Card, ErrorBox } from "../../../components/ui";
import { fmt, STATUS_LABEL } from "../../../lib/labels";
import { supabase } from "../../../lib/supabase";
import type { Status } from "../../../lib/types";
import { ACTION_LABEL, type SectionProps } from "../types";

interface Event {
  event_id:string; occurred_at:string; actor_id:string|null; note:string|null;
  kind:"status"|"review"|"resubmit"|"claim"|"release"|"transfer";
  detail:{from?:Status;to?:Status;round?:number;level?:number;action?:string;effective?:boolean;
    principal?:string;reassigned?:string;from_owner?:string;to_owner?:string}|null;
}

function description(event:Event,name:SectionProps["name"]) {
  const data=event.detail??{};
  switch(event.kind){
    case "status":return (data.from?STATUS_LABEL[data.from]:"—")+" → "+(data.to?STATUS_LABEL[data.to]:"—");
    case "review":return `第 ${data.round} 輪・第 ${data.level} 層：${ACTION_LABEL[data.action??""]}${data.effective?"":"（已失效）"}${data.principal?"・代理 "+name(data.principal):""}`;
    case "resubmit":return `第 ${data.round} 輪重送說明`;
    case "claim":return "認領";
    case "release":return "解除認領"+(data.reassigned?" → "+name(data.reassigned):"");
    case "transfer":return "負責人移交："+name(data.from_owner)+" → "+name(data.to_owner);
  }
}

const PAGE_SIZE=20;

export default function HistorySection({d,name}:SectionProps){
  const [page,setPage]=useState(1);
  const [rows,setRows]=useState<Event[]>([]);
  const [total,setTotal]=useState(0);
  const [loading,setLoading]=useState(true);
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    let current=true;
    const start=(page-1)*PAGE_SIZE;
    setLoading(true);setError(null);
    void supabase.from("v_case_timeline").select("*",{count:"exact"}).eq("request_id",d.r.id)
      .order("occurred_at",{ascending:false}).order("event_id",{ascending:false})
      .range(start,start+PAGE_SIZE-1).then(result=>{
        if(!current)return;
        if(result.error)setError(new Error(result.error.message));
        setRows(result.data??[]);setTotal(result.count??0);setLoading(false);
      });
    return ()=>{current=false};
  },[page,d.r.id,d.r.version]);
  const pages=Math.max(1,Math.ceil(total/PAGE_SIZE));
  return <Card title="案件歷程"><ErrorBox error={error}/>
    {loading?<p>載入中…</p>:!error && (rows.length?<div className="tablewrap"><table>
      <thead><tr><th>時間</th><th>事件</th><th>操作者</th><th>說明</th></tr></thead>
      <tbody>{rows.map(row=><tr key={row.event_id}><td>{fmt(row.occurred_at)}</td><td>{description(row,name)}</td>
        <td>{name(row.actor_id)}</td><td>{row.note??"—"}</td></tr>)}</tbody></table></div>:<p>尚無歷程。</p>)}
    {pages>1 && <nav className="r8-actions" aria-label="案件歷程分頁">
      <button disabled={loading||page<=1} onClick={()=>setPage(page-1)}>上一頁</button>
      <span>第 {page} / {pages} 頁</span>
      <button disabled={loading||page>=pages} onClick={()=>setPage(page+1)}>下一頁</button>
    </nav>}
  </Card>;
}
