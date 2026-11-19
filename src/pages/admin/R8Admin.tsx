import ExceptionInbox from "./ExceptionInbox";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { rpc, query } from "../../lib/api";
import { ErrorBox } from "../../components/ui";
import { useAuth } from "../../lib/auth";

const menu = [["employees","員工帳號與角色"],["departments","部門與主管"],["delegations","代理審核"],["all","全部案件"],["alerts","管理警示"],["audit","稽核紀錄"]];
export default function R8Admin() {
  const {me}=useAuth();
  const [counts,setCounts]=useState<number[]>([]);
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    Promise.all([
      query(supabase.from("employees").select("id").eq("is_active",true)),
      query(supabase.from("v_requests").select("status,is_receipt_overdue")),
      rpc<unknown[]>("admin_alerts")
    ]).then(([employees,cases,alerts])=>setCounts([employees.length,
      cases.filter(c=>c.status==="ISSUE_ABNORMAL").length,alerts.length,cases.filter(c=>c.is_receipt_overdue).length])).catch(setError);
  },[]);
  return <div className="r8-admin"><nav className="side"><b>工作總覽</b>{menu.map(([path,title])=><Link key={path} to={'/admin/'+path}>{title}</Link>)}</nav>
    <section><h1>系統管理工作首頁</h1><ErrorBox error={error}/><div className="r8-metrics">{["啟用員工","整案異常待辦","流程警示","簽收逾期案件"].map((title,i)=><div className="r8-meter" key={title}><strong>{counts[i]??"—"}</strong>{title}</div>)}</div>
    <div className="cols"><section className="r8-card"><h2>優先處理</h2><Link to="/admin/alerts">流程卡關警示</Link></section>
    <section className="r8-card"><h2>授權與角色</h2>{me?.roles.join("、")}</section></div><section className="r8-card"><h2>管理功能</h2><div className="r8-metrics">{menu.map(([path,title])=><Link className="r8-btn" key={path} to={'/admin/'+path}>{title}</Link>)}</div></section><ExceptionInbox/></section></div>;
}
