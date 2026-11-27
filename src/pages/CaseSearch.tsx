import { useEffect, useMemo, useState } from "react";
import { ErrorBox } from "../components/ui";
import { CaseRow } from "../components/CaseRow";
import { loadWorkRequests, type WorkRequest } from "../lib/workRequests";

/** 案件明細與操作（未選案件）：列出有權查看的案件，可依部門即時篩選 */
export default function CaseSearch() {
  const [rows, setRows] = useState<WorkRequest[] | null>(null);
  const [dept, setDept] = useState("");
  const [error, setError] = useState<unknown>();
  useEffect(() => {
    let current = true;
    loadWorkRequests().then(r => { if (current) setRows(r); }).catch(e => { if (current) setError(e); });
    return () => { current = false; };
  }, []);
  const departments = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of rows ?? []) m.set(r.department_id, r.department_name);
    return [...m].sort((a, b) => a[1].localeCompare(b[1], "zh-Hant"));
  }, [rows]);
  const shown = (rows ?? []).filter(r => !dept || r.department_id === dept);
  return <section className="r8-card"><ErrorBox error={error} />
    <div className="r8-toolbar"><h2 style={{ margin: 0 }}>案件查詢（{shown.length}）</h2>
      <label className="r8-row">部門
        <select value={dept} onChange={e => setDept(e.target.value)} aria-label="依部門篩選">
          <option value="">全部部門</option>
          {departments.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </select></label></div>
    {rows === null && !error ? <p className="r8-muted">載入中…</p>
      : shown.length ? shown.map(r => <CaseRow key={r.id} r={r} />) : <p>目前沒有案件。</p>}
  </section>;
}
