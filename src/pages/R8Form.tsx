import { useEffect } from "react";
import { rpc } from "../lib/api";
import { useAuth } from "../lib/auth";

declare global {
  interface Window { saveR8?: (args: Record<string, unknown>) => Promise<string> }
}

export default function R8Form() {
  const {me} = useAuth();
  useEffect(() => {
    window.saveR8 = args => rpc<string>("save_r8_application", args);
    return () => { delete window.saveR8; };
  }, []);
  return <iframe className="r8-form" src="./r8-form.html" title="新增圖面申請" onLoad={event => {
    const label = event.currentTarget.contentDocument?.getElementById("applicant");
    if (label && me) label.textContent = me.employee_no + "｜" + me.name;
  }} />;
}
