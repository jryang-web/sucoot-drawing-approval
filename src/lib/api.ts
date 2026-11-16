import { supabase } from "./supabase";

export class ApiError extends Error {
  constructor(public code: string, message: string) {
    super(message);
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
