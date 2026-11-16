import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { query, rpc } from "../lib/api";
import type { Item, RequestRow } from "../lib/types";
import { ErrorBox, useAction } from "../components/ui";

type Draft = Pick<Item, "drawing_no" | "drawing_name" | "purpose" | "needed_date" | "is_urgent"> & {
  revision: string; urgency_reason: string; remark: string;
};
const blank = (): Draft => ({ drawing_no: "", drawing_name: "", revision: "", purpose: "", needed_date: "", is_urgent: false, urgency_reason: "", remark: "" });

export default function RequestForm() {
  const { id } = useParams();
  const nav = useNavigate();
  const [note, setNote] = useState("");
  const [items, setItems] = useState<Draft[]>([blank()]);
  const [req, setReq] = useState<RequestRow | null>(null);
  const { busy, error, run } = useAction();

  useEffect(() => {
    if (!id) return;
    (async () => {
      const r = await query<RequestRow>(supabase.from("v_requests").select("*").eq("id", id).single());
      const its = await query<Item[]>(supabase.from("drawing_request_items").select("*").eq("request_id", id).order("line_no"));
      setReq(r); setNote(r.note ?? "");
      setItems(its.map((i) => ({ ...i, revision: i.revision ?? "", urgency_reason: i.urgency_reason ?? "", remark: i.remark ?? "" })));
    })().catch(() => {});
  }, [id]);

  const set = (i: number, patch: Partial<Draft>) => setItems((xs) => xs.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  const save = async (submit: boolean) => {
    let newId = id;
    const ok = await run(async () => {
      newId = await rpc<string>("save_draft", { p_request_id: id ?? null, p_note: note, p_items: items, p_expected_version: req?.version ?? null });
      if (submit && (!req || req.status === "DRAFT")) {
        await rpc("submit_request", { p_id: newId });
      }
    });
    if (ok) nav(`/r/${newId}`);
  };

  return (
    <div className="card">
      <h1>{id ? `編輯 ${req?.request_no ?? ""}` : "新增圖面申請"}</h1>
      {req?.status === "RETURNED" && <p className="muted">此案件已退回。修改後請回到案件頁面「重新送出」，重送時需填寫回覆說明（內容未修改時為必填）。</p>}
      {items.map((it, i) => (
        <fieldset key={i} className="card" style={{ background: "#fafbfc" }}>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <strong>第 {i + 1} 筆</strong>
            {items.length > 1 && <button type="button" className="danger" onClick={() => setItems((xs) => xs.filter((_, j) => j !== i))}>刪除</button>}
          </div>
          <div className="grid2">
            <div><label>圖號 *</label><input value={it.drawing_no} onChange={(e) => set(i, { drawing_no: e.target.value })} /></div>
            <div><label>圖名 *</label><input value={it.drawing_name} onChange={(e) => set(i, { drawing_name: e.target.value })} /></div>
            <div><label>版次（選填）</label><input value={it.revision} onChange={(e) => set(i, { revision: e.target.value })} /></div>
            <div><label>需求日期 *</label><input type="date" value={it.needed_date} onChange={(e) => set(i, { needed_date: e.target.value })} /></div>
          </div>
          <label>申請用途 *</label><input value={it.purpose} onChange={(e) => set(i, { purpose: e.target.value })} />
          <label><input type="checkbox" checked={it.is_urgent} onChange={(e) => set(i, { is_urgent: e.target.checked })} />急件</label>
          {it.is_urgent && <><label>急件原因 *</label><input value={it.urgency_reason} onChange={(e) => set(i, { urgency_reason: e.target.value })} /></>}
          <label>備註</label><input value={it.remark} onChange={(e) => set(i, { remark: e.target.value })} />
        </fieldset>
      ))}
      <button type="button" onClick={() => setItems((xs) => [...xs, blank()])}>＋ 新增一筆圖號</button>
      <label>整案備註</label><textarea value={note} onChange={(e) => setNote(e.target.value)} />
      <ErrorBox error={error} />
      <div className="row" style={{ marginTop: 12 }}>
        <button disabled={busy} onClick={() => save(false)}>儲存草稿</button>
        {(!req || req.status === "DRAFT") && <button className="primary" disabled={busy} onClick={() => save(true)}>儲存並送出</button>}
      </div>
    </div>
  );
}
