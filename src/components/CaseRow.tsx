import { Link } from "react-router-dom";
import { STATUS_LABEL } from "../lib/labels";
import type { RequestRow } from "../lib/types";

export function CaseRow({ r }: { r: RequestRow }) {
  return <div className="r8-case-row"><div><b>{r.request_no}</b> <span className="r8-pill">{STATUS_LABEL[r.status]}</span>
    <div className="r8-muted">{r.department_name}｜{r.item_count} 筆｜{r.is_urgent ? "急件" : "一般件"}</div></div>
    <Link className="r8-btn" to={"/r/" + r.id}>查看案件</Link></div>;
}
