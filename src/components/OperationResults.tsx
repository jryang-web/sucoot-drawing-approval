import { useEffect,useState } from "react";
import { acknowledge,operationLabels,resultEvent,resultsFor,type OperationResult } from "../lib/operations";

export default function OperationResults({user}:{user:string}){
  const [rows,setRows]=useState<OperationResult[]>([]);
  const [error,setError]=useState("");
  const [refresh,setRefresh]=useState(0);
  useEffect(()=>{
    let generation=0;
    const load=async()=>{
      const current=++generation;
      try {
        const found=await resultsFor(user);
        if(current===generation){setRows(found);setError("");}
      }catch{if(current===generation)setError("無法查詢操作結果，請重新查詢或登入。");}
    };
    void load();
    window.addEventListener(resultEvent,load);
    window.addEventListener("online",load);
    return ()=>{++generation;window.removeEventListener(resultEvent,load);window.removeEventListener("online",load)};
  },[user,refresh]);
  useEffect(()=>{
    const ids=rows.filter(row=>row.result).map(row=>row.id);
    if(!ids.length)return;
    let first=0,second=0,active=true;
    const displayed=()=>{
      if(document.visibilityState!=="visible")return;
      first=requestAnimationFrame(()=>{second=requestAnimationFrame(()=>{
        if(document.visibilityState==="visible")void acknowledge(user,ids).catch(()=>{
          if(active)setError("結果已顯示，回報失敗。請重新查詢。");
        });
      })});
    };
    displayed();document.addEventListener("visibilitychange",displayed);
    return ()=>{active=false;cancelAnimationFrame(first);cancelAnimationFrame(second);document.removeEventListener("visibilitychange",displayed)};
  },[user,rows]);
  if(!rows.length && !error)return null;
  return <section className="r8-card" role="dialog" aria-label="操作結果"><h2>操作結果</h2>
    {error && <p role="alert">{error}</p>}
    {rows.map(row=><p key={row.id}><b>{operationLabels[row.action]}</b> {row.result?.number??row.case_id??"尚無確認案號"}｜
      {row.result ? row.result.ok?"已成功":row.result.error : "尚未確認，請先查詢結果"}<br/><small>操作識別碼：{row.id}</small></p>)}
    <button onClick={()=>setRefresh(n=>n+1)}>重新查詢</button>
    <button onClick={()=>setRows([])}>關閉</button>
  </section>;
}
