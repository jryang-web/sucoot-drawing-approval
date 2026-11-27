import { query } from "./api";
import { supabase } from "./supabase";
import type { RequestRow } from "./types";

export type WorkRequest = RequestRow & { approved_l1_by_me: boolean };

/** 讀取登入者有權查看的全部案件（後端 v_work_requests 依權限過濾），新到舊 */
export async function loadWorkRequests(): Promise<WorkRequest[]> {
  const requests: WorkRequest[] = [];
  const pageSize = 500;
  for (;;) {
    const batch = await query<WorkRequest[]>(supabase.from("v_work_requests").select("*")
      .order("updated_at", { ascending: false }).order("id").range(requests.length, requests.length + pageSize - 1));
    requests.push(...batch);
    if (batch.length < pageSize) break;
  }
  return requests;
}
