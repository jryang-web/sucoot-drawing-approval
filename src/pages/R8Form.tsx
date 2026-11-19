import MockLine from "../components/MockLine";
import { Link } from "react-router-dom";
import { useEffect,useState } from "react";
import { rpc } from "../lib/api";
import { useAuth } from "../lib/auth";

declare global {
  interface Window { saveR8?: (args: Record<string, unknown>) => Promise<string> }
}

export default function R8Form() {
  const {me} = useAuth();
  const [sent,setSent]=useState("");
  useEffect(() => {
    window.saveR8 = async args => {
      const id=await rpc<string>("save_r8_application",args);
      if(args.p_submit)setSent(id);
      return id;
    };
    return () => { delete window.saveR8; };
  }, []);
  if(sent)return <><div className="r8-card"><h2>首次申請已送出</h2><Link to={"/r/"+sent}>查看案件</Link></div><MockLine id={sent}/></>;
  return <iframe className="r8-form" src="./r8-form.html" title="新增圖面申請" onLoad={event => {
    const label = event.currentTarget.contentDocument?.getElementById("applicant");
    if (label && me) label.textContent = me.employee_no + "｜" + me.name;
  }} />;
}
