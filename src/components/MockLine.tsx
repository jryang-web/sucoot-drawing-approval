import { useEffect, useState } from "react";
import { query, rpc } from "../lib/api";
import { supabase } from "../lib/supabase";
import { ErrorBox, useAction } from "./ui";

interface Event { event: string; message: string; simulated_at: string | null }

export default function MockLine({id, version}: {id:string; version?:number}) {
  const [events,setEvents]=useState<Event[]>([]);
  const [notice,setNotice]=useState("");
  const action=useAction();
  const {setError}=action;
  useEffect(()=>{
    let active=true;
    query<Event[]>(supabase.from("line_mock_events").select("event,message,simulated_at")
      .eq("request_id",id).order("occurred_at",{ascending:false})).then(rows=>{
        if(active) setEvents(rows);
      }).catch(e=>{if(active)setError(e)});
    return ()=>{active=false};
  },[id,version,setError]);
  return <><ErrorBox error={action.error}/>{events.map(event=>{
    const text=event.message+"\nAPP 案件連結："+location.origin+location.pathname+"#/r/"+id;
    return <section key={event.event} className="r8-line"><h3>APP 作業完成｜LINE 群組通知</h3>
      <textarea readOnly aria-label="完整通知訊息" value={text}/>
      <div className="r8-actions"><button disabled={action.busy || !!event.simulated_at} onClick={()=>action.run(async()=>{
        await rpc("simulate_line_event",{p_id:id,p_event:event.event});
        setEvents(rows=>rows.map(row=>row.event===event.event?{...row,simulated_at:new Date().toISOString()}:row));
      })}>{event.simulated_at?"已完成模擬":"模擬自動傳送"}</button>
      <button onClick={()=>action.run(async()=>{await navigator.clipboard.writeText(text);setNotice("已複製完整訊息")})}>手動複製完整訊息</button></div>
      <p role="status">{notice || "本機 Mock，不會傳送真實 LINE 訊息。"}</p></section>
  })}</>;
}
