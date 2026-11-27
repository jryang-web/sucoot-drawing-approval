import { useState, type FormEvent, type ReactNode } from "react";
import { accountAction } from "../lib/api";
import { useAuth } from "../lib/auth";
import { ErrorBox, useAction } from "../components/ui";

export default function ChangePassword({ forced, before }: { forced?: boolean; before?: ReactNode }) {
  const { signOut } = useAuth();
  const [cur, setCur] = useState("");
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");

  const { busy, error, setError, run } = useAction();

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (pw !== pw2) { setError(new Error("兩次輸入的新密碼不一致")); return; }
    if (!confirm("修改成功後所有裝置將登出；尚未成功提交的重要操作可能取消，且被取消操作的未提交表單內容無法恢復。確定修改？")) return;
    if (await run(() => accountAction({ action: "change_own_password", current_password: cur, new_password: pw, confirm_password: pw2 }))) {
      setCur(""); setPw(""); setPw2("");
      await signOut();
    }
  };

  return (
    <main style={{ maxWidth: 460 }}>
      {before}
      <div className="card">
        <h1>{forced ? "首次登入：請修改密碼" : "修改密碼"}</h1>
        {forced && <p className="muted">管理者設定的初始密碼必須修改後才能使用系統。</p>}
        <form onSubmit={submit}>
          <label>目前密碼</label>
          <input type="password" value={cur} onChange={(e) => setCur(e.target.value)} autoComplete="current-password" required />
          <label>新密碼（至少 8 碼）</label>
          <input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" minLength={8} required />
          <label>再次輸入新密碼</label>
          <input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} autoComplete="new-password" minLength={8} required />
          <ErrorBox error={error} />
          <div className="row" style={{ marginTop: 12 }}>
            <button className="primary" disabled={busy}>更新密碼</button>
            {forced && <button type="button" onClick={signOut}>登出</button>}
          </div>
        </form>
      </div>
    </main>
  );
}
