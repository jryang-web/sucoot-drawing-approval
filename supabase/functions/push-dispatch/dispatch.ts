// SUCOOT V5.9.1 | 推播佇列發送核心（Edge Function 與隔離測試共用）
// 流程：svc_push_claim 取出到期佇列（資料庫已重新確認收件資格並附上即時角標）→ 逐裝置加密送出 → svc_push_report 回報。
// 「accepted」只代表推播服務（FCM／Apple 等）已接受，不代表裝置已收到或角標已更新。
// 日誌與回傳值只含數量，不含 endpoint、金鑰、通知內容或個人資料。
import { sendWebPush, type SendResult, type VapidKeys } from "./webpush.ts";

export interface Subscription { id: string; endpoint: string; p256dh: string; auth: string }
export interface Batch {
  employee_id: string; outbox_ids: number[]; count: number; request_id: string; kind: string; badge: number;
  subscriptions: Subscription[];
}
export interface Store {
  claim(limit: number): Promise<Batch[]>;
  report(outboxIds: number[], results: Array<SendResult & { subscription_id: string }>): Promise<unknown>;
}

const KIND_LABEL: Record<string, string> = {
  L1: "第一層待審", L2: "第二層待審", ISSUE: "圖面待發行", RETURNED: "退回補件", RECEIPT: "待簽收", ABNORMAL: "整案異常待辦",
};
// V5.9.2 案件結果通知（不顯示案件編號，只顯示類別摘要）
const RESULT_LABEL: Record<string, string> = {
  R_REJECTED: "申請已駁回", R_FORCE_CLOSED: "案件已結案", R_CANCELLED: "申請已取消", R_RECEIPT_DONE: "已完成簽收",
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// 通知內容：只有待辦類別與數量，不含案件編號、申請人、產品明細等資料
export function buildPayload(b: Batch) {
  const result = RESULT_LABEL[b.kind];
  const label = KIND_LABEL[b.kind] ?? "待辦";
  const body = b.count > 1 ? `有 ${b.count} 則新的通知`
    : result ? `有 1 則「${result}」通知` : `有 1 件「${label}」案件等待處理`;
  return {
    v: 1,
    badge: Math.max(0, Math.min(b.badge | 0, 9999)),
    title: "SUCOOT 圖面申請",
    body,
    url: b.count === 1 && UUID.test(b.request_id) ? `#/r/${b.request_id}` : "#/my",
    tag: "sucoot-pending",
  };
}

async function pool<T, R>(items: T[], limit: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k]); }
  }));
  return out;
}

export interface DispatchSummary { batches: number; events: number; accepted: number; failed: number; no_subscription: number }

export async function dispatch(store: Store, keys: VapidKeys,
  opts: { maxRounds?: number; batchSize?: number; extraHosts?: string[]; fetchImpl?: typeof fetch } = {}): Promise<DispatchSummary> {
  const sum: DispatchSummary = { batches: 0, events: 0, accepted: 0, failed: 0, no_subscription: 0 };
  for (let round = 0; round < (opts.maxRounds ?? 5); round++) {
    const batches = await store.claim(opts.batchSize ?? 50);
    if (!batches.length) break;
    for (const b of batches) {
      sum.batches++; sum.events += b.outbox_ids.length;
      if (!b.subscriptions.length) { sum.no_subscription++; await store.report(b.outbox_ids, []); continue; }
      const payload = buildPayload(b);
      const results = await pool(b.subscriptions, 10, async (s) => ({
        subscription_id: s.id,
        ...await sendWebPush(s, payload, keys, { urgency: "high", topic: "sucoot-pending", extraHosts: opts.extraHosts, fetchImpl: opts.fetchImpl }),
      }));
      for (const r of results) r.accepted ? sum.accepted++ : sum.failed++;
      // 回報失敗不得中斷其他員工的發送；佇列鎖 2 分鐘後自動釋放並重試
      await store.report(b.outbox_ids, results).catch(() => {});
    }
  }
  return sum;
}
