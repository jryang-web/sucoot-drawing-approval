import ExceptionInbox from "./ExceptionInbox";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { rpc } from "../../lib/api";
import { ErrorBox } from "../../components/ui";
import { useAuth } from "../../lib/auth";

const menu = [["employees","員工帳號與角色"],["departments","部門與主管"],["delegations","代理審核"],["all","全部案件"],["alerts","管理警示"],["audit","稽核紀錄"]];
export default function R8Admin() {
  const {me}=useAuth();
  const [counts,setCounts]=useState<number[]>([]);
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    Promise.all([
      supabase.from("employees").select("id",{count:"exact",head:true}).eq("is_active",true),
      supabase.from("v_requests").select("id",{count:"exact",head:true}).eq("status","ISSUE_ABNORMAL"),
      supabase.from("v_requests").select("id",{count:"exact",head:true}).eq("is_receipt_overdue",true),
      rpc<unknown[]>("admin_alerts")
    ]).then(([employees,abnormal,overdue,alerts])=>{
      for(const result of [employees,abnormal,overdue])if(result.error)throw new Error(result.error.message || `統計查詢失敗（HTTP ${result.status}）`);
      if ([employees,abnormal,overdue].some(result=>result.count===null)) throw new Error("統計查詢未回傳筆數");
      setCounts([employees.count??0,abnormal.count??0,alerts.length,overdue.count??0]);
    }).catch(setError);
  },[]);
  return <div className="r8-admin"><nav className="side"><b>工作總覽</b>{menu.map(([path,title])=><Link key={path} to={'/admin/'+path}>{title}</Link>)}</nav>
    <section><h1>系統管理工作首頁</h1><ErrorBox error={error}/><div className="r8-metrics">{["啟用員工","整案異常待辦","流程警示","簽收逾期案件"].map((title,i)=>{
      const filter=i===1?"ISSUE_ABNORMAL":i===3?"OVERDUE":null;
      const label=<><strong>{counts[i]??"—"}</strong>{title}</>;
      return filter?<Link className="r8-meter" key={title} to={"/admin/all?status="+filter}>{label}</Link>
        :<div className="r8-meter" key={title}>{label}</div>;
    })}</div>
    <div className="cols"><section className="r8-card"><h2>優先處理</h2><Link to="/admin/alerts">流程卡關警示</Link></section>
    <section className="r8-card"><h2>授權與角色</h2>{me?.roles.join("、")}</section></div><section className="r8-card"><h2>管理功能</h2><div className="r8-metrics">{menu.map(([path,title])=><Link className="r8-btn" key={path} to={'/admin/'+path}>{title}</Link>)}</div></section><ExceptionInbox/></section></div>;
}
