import { useState, type FormEvent } from "react";
import { supabase, emailOf } from "../lib/supabase";
import { ErrorBox } from "../components/ui";
import { APP_STAGE } from "../config";

export default function Login({ notice }: { notice?: string | null }) {
  const [no, setNo] = useState("");
  const [pw, setPw] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email: emailOf(no), password: pw });
    setBusy(false);
    if (error) setError(/banned/i.test(error.message) ? "帳號已停用，請洽系統管理員" : "員工編號或密碼錯誤");
  };

  return (
    <main style={{ maxWidth: 420 }}>
      <div className="card">
        <h1>SUCOOT 圖面申請與審核{APP_STAGE && <span className="stage">{APP_STAGE}</span>}</h1>
        <form onSubmit={submit}>
          <label htmlFor="no">員工編號</label>
          <input id="no" value={no} onChange={(e) => setNo(e.target.value)} autoComplete="username" autoCapitalize="none" required />
          <label htmlFor="pw">密碼</label>
          <input id="pw" type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="current-password" required />
          {notice && <div className="err">{notice}</div>}
          <ErrorBox error={error} />
          <div style={{ marginTop: 12 }}><button className="primary" disabled={busy} style={{ width: "100%" }}>登入</button></div>
        </form>
        <p className="muted">帳號由系統管理員建立；忘記密碼請洽系統管理員重設。</p>
      </div>
    </main>
  );
}
