import { useState, type ReactNode } from "react";
import { STATUS_LABEL } from "../lib/labels";
import type { Status } from "../lib/types";

export function StatusBadge({ status, overdue }: { status: Status; overdue?: boolean }) {
  const cls = status === "COMPLETED" ? "ok" : ["REJECTED", "CANCELLED", "ISSUE_ABNORMAL"].includes(status) ? "danger"
    : status === "RETURNED" ? "warn" : "";
  return (
    <span className="row" style={{ display: "inline-flex", gap: 4 }}>
      <span className={`badge ${cls}`}>{STATUS_LABEL[status]}</span>
      {overdue && <span className="badge danger">簽收逾期</span>}
    </span>
  );
}

export function ErrorBox({ error }: { error: unknown }) {
  if (!error) return null;
  return <div className="err">{error instanceof Error ? error.message : String(error)}</div>;
}

// 執行非同步動作並統一處理 loading / 錯誤
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); return true; } catch (e) { setError(e); return false; } finally { setBusy(false); }
  };
  return { busy, error, setError, run };
}

export function Card({ title, children, right }: { title?: string; children: ReactNode; right?: ReactNode }) {
  return (
    <section className="card">
      {(title || right) && <div className="row" style={{ justifyContent: "space-between" }}>{title && <h2>{title}</h2>}{right}</div>}
      {children}
    </section>
  );
}
