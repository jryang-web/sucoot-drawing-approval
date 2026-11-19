import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { query } from "../../lib/api";
import type { DirectoryEntry, Item, RequestRow } from "../../lib/types";
import type { Abnormal, Claim, Detail, History, Review, Revision, Transfer } from "./types";

/** 載入案件明細所需的全部資料（各表皆受 RLS 限制） */
export function useRequestDetail(id: string) {
  const [data, setData] = useState<Detail | null>(null);
  const [error, setError] = useState<unknown>(null);

  const reload = useCallback(async () => {
    try {
      const r = await query<RequestRow>(supabase.from("v_requests").select("*").eq("id", id).single());
      const [items, reviews, history, claims, abnormal, transfers, revisions, people, exception] = await Promise.all([
        query<Item[]>(supabase.from("drawing_request_items").select("*").eq("request_id", id).order("line_no")),
        query<Review[]>(supabase.from("review_records").select("*").eq("request_id", id).order("created_at")),
        query<History[]>(supabase.from("request_status_history").select("*").eq("request_id", id).order("id")),
        query<Claim[]>(supabase.from("issue_claims").select("*").eq("request_id", id).order("claimed_at")),
        query<Abnormal[]>(supabase.from("item_abnormal_reports").select("*").eq("request_id", id).order("reported_at")),
        query<Transfer[]>(supabase.from("ownership_transfers").select("*").eq("request_id", id).order("created_at")),
        query<Revision[]>(supabase.from("request_revisions").select("round,resubmit_note,submitted_at").eq("request_id", id).order("round")),
        query<DirectoryEntry[]>(supabase.from("v_employee_directory").select("*")),
        query<Detail["exception"]>(supabase.from("case_exceptions").select("reason,withdrawal_reason").eq("request_id",id).maybeSingle()),
      ]);
      setData({ r, items, reviews, history, claims, abnormal, transfers, revisions, exception,
        people: Object.fromEntries(people.map((p) => [p.id, p])) });
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [id]);

  useEffect(() => { reload(); }, [reload]);
  return { data, error, reload };
}
