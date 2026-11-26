import { useCallback, useEffect, useState, type ChangeEvent } from "react";
import { Link } from "react-router-dom";
import { rpc } from "../../lib/api";
import { ErrorBox } from "../../components/ui";
import "./ProductMaster.css";

interface Batch {
  batch_id: string; file_name: string; status: "PREVIEWED" | "REJECTED" | "COMMITTED"; total: number;
  added: number; updated: number; unchanged: number; reactivated: number; deactivated: number; active_before: number;
  error_count: number; errors?: { row: number | null; code: string | null; message: string }[];
  warnings?: { codes: string[] }[]; high_risk: boolean; can_commit: boolean;
  created_at: string; committed_at: string | null; created_by: string; committed_by: string | null;
}
interface Summary { active: number; inactive: number; version: number; batches: Batch[] }

const STATUS: Record<Batch["status"], string> = { PREVIEWED: "已預覽（未同步）", REJECTED: "有錯誤（不可同步）", COMMITTED: "已同步" };
const time = (s: string | null) => (s ? new Date(s).toLocaleString("sv-SE", { timeZone: "Asia/Taipei" }) : "—");

/** 產品主檔管理：Excel 完整同步（第一階段預覽、第二階段確認）。不提供逐筆編輯；權限由後端驗證。 */
export default function ProductMaster() {
  const [summary, setSummary] = useState<Summary | null>(null);
  const [preview, setPreview] = useState<Batch | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [done, setDone] = useState<Batch | null>(null);
  const [busy, setBusy] = useState<"" | "reading" | "preview" | "commit">("");
  const [error, setError] = useState<unknown>(null);
  const [riskAck, setRiskAck] = useState(false);
  const [riskText, setRiskText] = useState("");

  const load = useCallback(() => rpc<Summary>("admin_product_master_summary").then(setSummary).catch(setError), []);
  useEffect(() => { load(); }, [load]);

  const onFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    setError(null); setPreview(null); setDone(null); setNote(null); setRiskAck(false); setRiskText("");
    try {
      setBusy("reading");
      const { readProductSheet, sha256 } = await import("../../lib/xlsx");
      const sheet = await readProductSheet(file);
      setNote(`工作表「${sheet.sheetName}」，讀取 ${sheet.rows.length.toLocaleString()} 列` +
        (sheet.numericCells ? `；其中 ${sheet.numericCells} 個儲存格為數值格式，已依原始儲存內容讀取，請核對編碼` : ""));
      setBusy("preview");
      const result = await rpc<Batch>("admin_product_import_preview", {
        p_file_name: file.name, p_file_sha256: await sha256(file), p_header: sheet.header, p_rows: sheet.rows,
      });
      setPreview(result);
      load();
    } catch (err) {
      setError(err);
    } finally {
      setBusy("");
    }
  };

  const commit = async () => {
    if (!preview) return;
    if (!confirm(`確定以「${preview.file_name}」完整同步產品主檔？\n新增 ${preview.added}、更新 ${preview.updated}、重新啟用 ${preview.reactivated}、停用 ${preview.deactivated}。`)) return;
    setBusy("commit"); setError(null);
    try {
      const result = await rpc<Batch>("admin_product_import_commit", { p_batch_id: preview.batch_id, p_confirm_high_risk: preview.high_risk && riskAck });
      setDone(result); setPreview(null);
      load();
    } catch (err) {
      setError(err);
    } finally {
      setBusy("");
    }
  };

  const riskOk = !preview?.high_risk || (riskAck && riskText.trim() === "確認停用");

  return (
    <div className="pm">
      <div className="r8-toolbar">
        <h1 style={{ margin: 0 }}>產品主檔管理</h1>
        <Link className="r8-btn" to="/admin">返回系統管理</Link>
      </div>

      <section className="r8-card">
        <h2>目前產品主檔</h2>
        <div className="r8-metrics">
          <div className="r8-meter"><strong>{summary?.active.toLocaleString() ?? "—"}</strong><span>啟用產品</span></div>
          <div className="r8-meter"><strong>{summary?.inactive.toLocaleString() ?? "—"}</strong><span>停用產品</span></div>
          <div className="r8-meter"><strong>{summary ? `v${summary.version}` : "—"}</strong><span>主檔版本</span></div>
        </div>
      </section>

      <section className="r8-card r8-work">
        <h2>Excel 完整同步</h2>
        <ol className="pm-rules">
          <li>上傳完整產品清單（第一個工作表，第一列為「產品代碼、品名、規格」）。</li>
          <li>系統先驗證並顯示差異預覽，此時<strong>尚未修改</strong>產品主檔。</li>
          <li>確認後一次完成同步：新編碼新增、資料不同者更新、重新出現者重新啟用、未列於 Excel 者<strong>停用（不刪除）</strong>。</li>
        </ol>
        <label className="r8-btn r8-primary pm-upload">
          {busy === "reading" ? "讀取中…" : busy === "preview" ? "驗證中…" : "選擇 Excel 檔案（.xlsx）"}
          <input type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={onFile} disabled={!!busy} hidden />
        </label>
        {note && <p className="r8-muted">{note}</p>}
        <ErrorBox error={error} />
      </section>

      {preview && (
        <section className={`r8-card pm-preview ${preview.high_risk ? "pm-risk" : ""}`} aria-live="polite">
          <h2>差異預覽：{preview.file_name}</h2>
          <div className="pm-counts">
            {([["Excel 總筆數", preview.total], ["新增", preview.added], ["更新", preview.updated], ["不變", preview.unchanged],
               ["重新啟用", preview.reactivated], ["預計停用", preview.deactivated], ["錯誤", preview.error_count]] as const)
              .map(([label, n]) => (
                <div key={label} className={`r8-meter ${label === "錯誤" && n > 0 ? "pm-bad" : ""} ${label === "預計停用" && preview.high_risk ? "pm-bad" : ""}`}>
                  <strong>{n.toLocaleString()}</strong><span>{label}</span>
                </div>))}
          </div>

          {preview.error_count > 0 && <>
            <div className="err">此檔案有 {preview.error_count} 個錯誤，<strong>不能同步</strong>。請修正 Excel 後重新上傳。</div>
            <div className="tablewrap"><table className="pm-table"><thead><tr><th>列</th><th>產品代碼</th><th>錯誤</th></tr></thead><tbody>
              {preview.errors?.map((e, i) => <tr key={i}><td>{e.row ?? "—"}</td><td>{e.code ?? "—"}</td><td>{e.message}</td></tr>)}
            </tbody></table></div>
            {preview.error_count > (preview.errors?.length ?? 0) && <p className="r8-muted">僅顯示前 {preview.errors?.length} 個錯誤。</p>}
          </>}

          {preview.can_commit && <>
            {!!preview.warnings?.length && (
              <details className="pm-warn"><summary>提醒：{preview.warnings.length} 組編碼僅大小寫不同（視為不同產品，可同步）</summary>
                <ul>{preview.warnings.map((w) => <li key={w.codes.join()}>{w.codes.join("、")}</li>)}</ul>
              </details>)}
            {preview.high_risk && (
              <div className="pm-riskbox" role="alert">
                <strong>高風險：預計停用 {preview.deactivated.toLocaleString()} 筆，超過現有啟用產品（{preview.active_before.toLocaleString()} 筆）的 10%。</strong>
                <p>請確認上傳的是<strong>完整</strong>產品清單；不完整的檔案會造成大量產品停用，員工將搜尋不到。</p>
                <label><input type="checkbox" checked={riskAck} onChange={(e) => setRiskAck(e.target.checked)} /> 我已核對此檔案為完整產品清單</label>
                <label>請輸入「確認停用」<input value={riskText} onChange={(e) => setRiskText(e.target.value)} placeholder="確認停用" /></label>
              </div>)}
            <div className="r8-actions">
              <button className="r8-btn r8-primary" disabled={!!busy || !riskOk} onClick={commit}>{busy === "commit" ? "同步中…" : "確認同步產品主檔"}</button>
              <button className="r8-btn" disabled={!!busy} onClick={() => setPreview(null)}>取消</button>
            </div>
            <p className="r8-muted">預覽 60 分鐘內有效；若預覽後產品主檔已被其他匯入修改，系統會拒絕並要求重新預覽。</p>
          </>}
        </section>
      )}

      {done && (
        <div className="okmsg" role="status">
          已完成同步：新增 {done.added}、更新 {done.updated}、不變 {done.unchanged}、重新啟用 {done.reactivated}、停用 {done.deactivated}。
        </div>
      )}

      <section className="r8-card">
        <h2>匯入紀錄（最近 20 筆）</h2>
        <div className="tablewrap"><table className="pm-table"><thead><tr><th>時間</th><th>檔案</th><th>狀態</th><th>總筆數</th><th>新增／更新／重新啟用／停用</th><th>操作者</th></tr></thead><tbody>
          {summary?.batches.map((b) => (
            <tr key={b.batch_id}>
              <td>{time(b.committed_at ?? b.created_at)}</td><td>{b.file_name}</td><td>{STATUS[b.status]}{b.error_count > 0 && `（${b.error_count} 錯誤）`}</td>
              <td>{b.total.toLocaleString()}</td><td>{b.added}／{b.updated}／{b.reactivated}／{b.deactivated}</td><td>{b.committed_by ?? b.created_by}</td>
            </tr>))}
          {summary && summary.batches.length === 0 && <tr><td colSpan={6} className="r8-muted">尚無匯入紀錄</td></tr>}
        </tbody></table></div>
      </section>
    </div>
  );
}
