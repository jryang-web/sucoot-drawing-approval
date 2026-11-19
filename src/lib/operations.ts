import { supabase } from "./supabase";

export const operationLabels: Record<string,string> = {
  write_r8_application:"正式送件", submit_request:"送出申請", resubmit:"退回重送",
  review_level1:"第一層審核",review_level2:"第二層審核",claim_issue:"整案認領",
  record_issue:"登記發行",case_exception:"異常回報",withdraw_exception:"撤回異常",
  confirm_receipt:"整案簽收",admin_force_close:"強制結案",
};

interface Outcome {ok:boolean;id?:string;number?:string;error?:string}
export interface OperationResult {id:string;action:string;case_id:string|null;result:Outcome|null}
interface Marker {id:string;action:string;case_id:string|null;shown?:boolean}
const prefix=(user:string)=>"sucoot.operation."+user+".";
export const resultEvent="sucoot-operation-results";

function markers(user:string): [string,Marker][] {
  return Object.keys(localStorage).filter(k=>k.startsWith(prefix(user)))
    .map(k=>[k, JSON.parse(localStorage.getItem(k)!) as Marker]);
}
async function call<T>(name:string,args:Record<string,unknown>):Promise<T>{
  const {data,error}=await supabase.rpc(name,args);
  if(error)throw new Error(error.message);
  return data as T;
}
export async function resultsFor(user:string):Promise<OperationResult[]> {
  const local=markers(user).map(([,m])=>m);
  const rows=await call<OperationResult[]>("operation_results",{p_keys:local.map(m=>m.id)});
  const seen=new Set(rows.map(r=>r.id));
  const shown=new Set(local.filter(m=>m.shown).map(m=>m.id));
  return [...rows.filter(r=>!shown.has(r.id)),...local.filter(m=>!seen.has(m.id)).map(m=>({...m,result:null}))];
}
export async function acknowledge(user:string,ids:string[]) {
  await call("ack_operation_results",{p_keys:ids});
  const shown=new Set(ids);
  for(const [key,marker] of markers(user))if(shown.has(marker.id))localStorage.setItem(key,JSON.stringify({...marker,shown:true}));
}
function canonical(_key:string,value:unknown):unknown {
  if(value && typeof value==="object" && !Array.isArray(value))
    return Object.fromEntries(Object.entries(value).sort(([a],[b])=>a<b?-1:a>b?1:0));
  return value;
}
export async function businessOperation(fn:string,args:Record<string,unknown>) {
  const {data:{session}}=await supabase.auth.getSession();
  if(!session)throw new Error("請重新登入後查詢操作結果");
  const bytes=new TextEncoder().encode(JSON.stringify([fn,args],canonical));
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),n=>n.toString(16).padStart(2,"0")).join("");
  const storeKey=prefix(session.user.id)+digest;
  const bind=()=>{
    const previous=localStorage.getItem(storeKey);
    if(previous)return {key:(JSON.parse(previous) as Marker).id,retry:true};
    const key=crypto.randomUUID();
    localStorage.setItem(storeKey,JSON.stringify({id:key,action:fn,case_id:args.p_id??null}));
    return {key,retry:false};
  };
  const {key,retry}=navigator.locks ? await navigator.locks.request(storeKey,bind) : bind();
  try {
    let outcome:Outcome|null=null;
    if(retry){
      const results=await call<OperationResult[]>("operation_results",{p_keys:[key]});
      outcome=results.find(r=>r.id===key)?.result??null;
    }
    if(!outcome){
      await call("prepare_operation",{p_key:key,p_action:fn,p_args:args});
      try {
        outcome=await call<Outcome>("execute_operation",{p_key:key});
      } catch (error) {
        // A transport error may arrive after COMMIT. Look up this exact key;
        // a missing or pending result never authorizes an automatic resubmission.
        const latest=await call<OperationResult[]>("operation_results",{p_keys:[key]}).catch(()=>null);
        outcome=latest?.find(row=>row.id===key)?.result??null;
        if(!outcome){
          if(error instanceof Error && error.message.includes("IN_PROGRESS"))throw error;
          throw new Error("尚無已確認結果，請查詢操作結果或重新登入。操作識別碼："+key);
        }
      }
    }
    // Only the initiating action receiving a definite result releases its retry key.
    // The inbox may have displayed the result while that HTTP response was lost.
    if(JSON.parse(localStorage.getItem(storeKey)??"null")?.id===key)localStorage.removeItem(storeKey);
    if(!outcome.ok)throw new Error(outcome.error || "操作失敗");
    return fn==="write_r8_application"?outcome.id:null;
  } finally {
    window.dispatchEvent(new Event(resultEvent));
  }
}
