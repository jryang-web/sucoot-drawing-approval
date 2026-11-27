-- SUCOOT V5.9.1 | 推播排程重試：排程密鑰以 Vault 驗證
-- 排程（pg_cron＋pg_net）每分鐘從 Vault 讀取 sucoot_push_cron_secret 放在 x-push-cron-secret 標頭呼叫 push-dispatch；
-- push-dispatch 以本函式比對 Vault 中的值。密鑰在資料庫內產生並只存在 Vault，不經任何人或程式輸出。
-- 只回傳 true／false，不回傳密鑰；僅 service_role（Edge Function）可執行。
create or replace function public.svc_push_cron_ok(p_secret text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  if p_secret is null or length(p_secret) < 32 then return false; end if;
  select s.decrypted_secret into v from vault.decrypted_secrets s where s.name = 'sucoot_push_cron_secret';
  -- 以雜湊比對，避免依字元逐一比較
  return v is not null and extensions.digest(v, 'sha256') = extensions.digest(p_secret, 'sha256');
end $$;
revoke all on function public.svc_push_cron_ok(text) from public, anon, authenticated;
grant execute on function public.svc_push_cron_ok(text) to service_role;
