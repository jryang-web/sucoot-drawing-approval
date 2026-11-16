import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { rpc, ApiError } from "./api";
import type { Me, Role } from "./types";

interface AuthState {
  session: Session | null; me: Me | null; loading: boolean; error: string | null;
  reload: () => Promise<void>; signOut: () => Promise<void>; has: (r: Role) => boolean;
}
const Ctx = createContext<AuthState>(null as unknown as AuthState);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadMe = useCallback(async (s: Session | null) => {
    if (!s) { setMe(null); setLoading(false); return; }
    try {
      setMe(await rpc<Me>("me"));
      setError(null);
    } catch (e) {
      // 帳號停用或沒有員工資料：強制登出
      setMe(null);
      setError(e instanceof ApiError ? e.message : String(e));
      await supabase.auth.signOut();
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); loadMe(data.session); });
    const { data: sub } = supabase.auth.onAuthStateChange((evt, s) => {
      setSession(s);
      if (evt === "SIGNED_IN" || evt === "SIGNED_OUT") loadMe(s);
    });
    return () => sub.subscription.unsubscribe();
  }, [loadMe]);

  const value: AuthState = {
    session, me, loading, error,
    reload: () => loadMe(session),
    signOut: async () => { await supabase.auth.signOut(); },
    has: (r) => !!me?.roles.includes(r),
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useAuth = () => useContext(Ctx);
