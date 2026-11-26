-- 模擬正式 Supabase 的 safeupdate 規則（UPDATE／DELETE 必須有 WHERE）：
-- 掃描 public／app 所有函式內的 UPDATE／DELETE 陳述式（至分號為止），列出未含 WHERE 者。
-- 本機無法安裝 pg-safeupdate，故以靜態檢查補足；結果應為 0 列。
with stmts as (
  select n.nspname || '.' || p.proname as fn, m[1] as stmt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         regexp_matches(p.prosrc, '(?:^|[\s;(])((?:update|delete\s+from)\s+(?:only\s+)?[a-z_]+\.[a-z_]+[^;]*)', 'gi') m
   where n.nspname in ('public', 'app') and p.prokind = 'f'
)
select fn, left(regexp_replace(stmt, '\s+', ' ', 'g'), 120) as stmt_without_where
  from stmts where stmt !~* '\mwhere\M' and stmt !~* '\mcurrent\s+of\M'
 order by 1;
