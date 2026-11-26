import MockLine from "../components/MockLine";
import { ErrorBox } from "../components/ui";
import { Link,useParams } from "react-router-dom";
import { useEffect,useState } from "react";
import { query,rpc } from "../lib/api";
import { supabase } from "../lib/supabase";
import { useAuth } from "../lib/auth";
import type {Item,RequestRow} from "../lib/types";

type Draft=Pick<RequestRow,"id"|"note"|"version"|"status"> & {items:Item[]};
/** V5.9 產品主檔搜尋結果（後端只回傳啟用中產品，每頁 20 筆） */
type ProductSearch={items:{code:string;name:string;spec:string}[];has_more:boolean};
declare global {
  interface Window {
    saveR8?: (args: Record<string, unknown>) => Promise<string>;
    searchProducts?: (query: string, offset?: number) => Promise<ProductSearch>;
    loadDraft?: (draft:Draft)=>void;
  }
}

export default function R8Form() {
  const {me} = useAuth();
  const {id}=useParams();
  const [draft,setDraft]=useState<Draft|null>(null);
  const [sent,setSent]=useState("");
  const [error,setError]=useState<unknown>();
  useEffect(()=>{
    let active=true;
    setSent("");setDraft(null);setError(null);
    if(id)Promise.all([
      query<RequestRow>(supabase.from("v_requests").select("*").eq("id",id).single()),
      query<Item[]>(supabase.from("drawing_request_items").select("*").eq("request_id",id).order("line_no"))
    ]).then(([r,items])=>{
      if(!active)return;
      if(r.applicant_id!==me?.id || !["DRAFT","RETURNED"].includes(r.status))throw new Error("目前無權編輯此案");
      setDraft({...r,items});
    }).catch(e=>{if(active)setError(e)});
    return ()=>{active=false};
  },[id,me?.id]);
  useEffect(() => {
    window.saveR8 = async args => {
      if(id && draft?.id!==id)throw new Error("案件尚未載入");
      const saved=await rpc<string>("write_r8_application",{...args,p_id:id??null,p_version:draft?.version??null});
      if(args.p_submit)setSent(saved);
      return saved;
    };
    return () => { delete window.saveR8; };
  }, [id,draft]);
  useEffect(() => {
    window.searchProducts = (query, offset = 0) => rpc<ProductSearch>("search_products", { p_query: query, p_limit: 20, p_offset: offset });
    return () => { delete window.searchProducts; };
  }, []);
  if(error)return <ErrorBox error={error}/>;
  if(id && draft?.id!==id)return <p>載入中…</p>;
  if(sent)return <><div className="r8-card"><h2>首次申請已送出</h2><Link to={"/r/"+sent}>查看案件</Link></div><MockLine id={sent}/></>;
  return <iframe key={id??"new"} className="r8-form" src="./r8-form.html" title="圖面申請" onLoad={event => {
    const frame=event.currentTarget;
    const label=frame.contentDocument?.getElementById("applicant");
    if(label && me)label.textContent=me.employee_no+"｜"+me.name;
    if(id && draft)frame.contentWindow?.loadDraft?.(draft);
  }}/>;
}
