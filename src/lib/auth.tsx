import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabase";
import { rpc, ApiError } from "./api";
import type { Me, Role } from "./types";
import { stopBadge } from "./badge";
import { unregisterPushOnLogout } from "./push";

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
      void stopBadge();
      await supabase.auth.signOut();
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); loadMe(data.session); });
    const { data: sub } = supabase.auth.onAuthStateChange((evt, s) => {
      setSession(s);
      if (evt === "SIGNED_OUT") void stopBadge();   // V5.9.1：登出、工作階段失效時清除角標
      if (evt === "SIGNED_IN" || evt === "SIGNED_OUT") loadMe(s);
    });
    return () => sub.subscription.unsubscribe();
  }, [loadMe]);

  const value: AuthState = {
    session, me, loading, error,
    reload: () => loadMe(session),
    // V5.9.1：登出前停用此裝置在目前帳號的推播訂閱，並清除角標
    signOut: async () => { await unregisterPushOnLogout(); await stopBadge(); await supabase.auth.signOut(); },
    has: (r) => !!me?.roles.includes(r),
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useAuth = () => useContext(Ctx);
