import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { rpc } from "../../lib/api";
import { Card, ErrorBox, StatusBadge } from "../../components/ui";
import type { Status } from "../../lib/types";

interface Alert { request_id: string; request_no: string; status: Status; problem: string }

export default function Alerts() {
  const [rows, setRows] = useState<Alert[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { rpc<Alert[]>("admin_alerts").then(setRows).catch(setError); }, []);
  return (
    <Card title="需要管理員處理的案件">
      <p className="muted">組織設定不完整（部門無主管、無圖管人員、負責人已停用等）造成流程無法繼續的案件。</p>
      <ErrorBox error={error} />
      {rows && rows.length === 0 && <div className="okmsg">目前沒有卡住的案件</div>}
      <div className="list">{rows?.map((a, i) => (
        <Link key={i} to={`/r/${a.request_id}`} className="item">
          <div className="row" style={{ justifyContent: "space-between" }}><strong>{a.request_no}</strong><StatusBadge status={a.status} /></div>
          <div className="err" style={{ margin: "6px 0 0" }}>{a.problem}</div>
        </Link>))}</div>
    </Card>
  );
}
