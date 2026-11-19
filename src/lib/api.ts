import {businessOperation, operationLabels} from "./operations";
import { supabase } from "./supabase";

export class ApiError extends Error {
  constructor(public code: string, message: string) {
    super(message.replaceAll("圖號", "產品編碼").replaceAll("圖名", "品名/規格"));
  }
}

// 資料庫錯誤訊息格式："CODE: 訊息"
function toApiError(e: { message?: string; code?: string } | null | undefined): ApiError {
  const msg = e?.message ?? "未知錯誤";
  const m = /^([A-Z_]+): (.*)$/s.exec(msg);
  if (m) return new ApiError(m[1], m[2]);
  if (e?.code === "42501") return new ApiError("FORBIDDEN", "權限不足");
  return new ApiError(e?.code ?? "ERROR", msg);
}

export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  if(fn==="write_r8_application" && args.p_submit===false){
    const draft={...args};
    delete draft.p_submit;
    return rpc<T>("save_r8_draft",draft);
  }
  if(Object.prototype.hasOwnProperty.call(operationLabels,fn))return await businessOperation(fn,args) as T;
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw toApiError(error);
  return data as T;
}

export async function query<T = unknown>(p: PromiseLike<{ data: T | null; error: unknown }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw toApiError(error as { message?: string; code?: string });
  return data as T;
}

export async function accountAction<T = Record<string, unknown>>(body: Record<string, unknown>): Promise<T> {
  if (body.action === "change_own_password") return rpc<T>("change_employee_password", {
    p_current:body.current_password,p_new:body.new_password,p_confirmation:body.confirm_password,
  });
  if (body.action === "reset_password" || body.action === "set_active") return rpc<T>("manage_employee_login", {
    p_employee:body.employee_id,p_reason:body.reason,
    p_action:body.action==="reset_password"?"reset":body.active?"activate":"deactivate",
  });
  const { data, error } = await supabase.functions.invoke("admin-accounts", { body });
  if (error) {
    // FunctionsHttpError：讀取回應內容
    const ctx = (error as { context?: Response }).context;
    if (ctx && typeof ctx.json === "function") {
      const j = await ctx.json().catch(() => null);
      if (j?.code) throw new ApiError(j.code, j.message);
    }
    throw new ApiError("FUNCTION_ERROR", error.message);
  }
  return data as T;
}
