import type { DirectoryEntry, Item, RequestRow } from "../../lib/types";
import type { Me, Role } from "../../lib/types";

export interface Review { id: string; round: number; level: number; action: string; reviewer_id: string; on_behalf_of_id: string | null; comment: string | null; is_effective: boolean; created_at: string }
export interface History { id: number; from_status: string | null; to_status: string; actor_id: string | null; reason: string | null; created_at: string }
export interface Claim { id: string; staff_id: string; claimed_at: string; released_at: string | null; release_reason: string | null; reassigned_to: string | null }
export interface Abnormal { id: string; item_id: string; reason: string; status: "OPEN" | "REISSUED" | "CONFIRMED"; reported_at: string; reissued_at: string | null; confirmed_at: string | null }
export interface Revision { round: number; resubmit_note: string | null; submitted_at: string }

export interface Detail {
  r: RequestRow; items: Item[]; reviews: Review[]; history: History[]; claims: Claim[];
  notes: {id:number;actor_id:string;created_at:string;after:{category:string};reason:string}[];
  exception: {reason:string; withdrawal_reason:string|null} | null;
  abnormal: Abnormal[]; revisions: Revision[]; people: Record<string, DirectoryEntry>;
}

/** 每個區塊共用的內容：案件資料、目前使用者、執行動作的方法 */
export interface SectionProps {
  d: Detail;
  me: Me;
  has: (r: Role) => boolean;
  busy: boolean;
  /** 執行動作；成功後顯示訊息並重新載入，回傳是否成功 */
  run: (fn: () => Promise<unknown>, okMsg: string) => Promise<boolean>;
  /** 員工 id → 「姓名（編號）」 */
  name: (id: string | null | undefined) => string;
}

export const ACTION_LABEL: Record<string, string> = { APPROVE: "核准", RETURN: "退回", REJECT: "拒絕" };
export const activeClaim = (d: Detail) => d.claims.find((c) => !c.released_at);
