#!/usr/bin/env bash
# SUCOOT V5.9｜多管理員並發匯入測試（只可在隔離本機資料庫執行；會實際寫入產品主檔）
# 兩位管理員各自依同一主檔版本完成預覽，同時按下「確認同步」（檔案為測試資料，已含高風險額外確認）：
#   預期恰好一位成功、另一位因 STALE_PREVIEW 被拒；主檔版本只 +1；資料與成功者的檔案一致。
set -euo pipefail
: "${PGHOST:?請指向隔離資料庫}"
q() { psql -qtA -v ON_ERROR_STOP=1 "$@"; }
as_user() { # $1=員工編號 $2=SQL
  q <<SQL
select set_config('request.jwt.claims', jsonb_build_object('sub', e.auth_user_id, 'session_id', s.id, 'role', 'authenticated')::text, false)
  from public.employees e join lateral (select id from auth.sessions where user_id = e.auth_user_id order by created_at desc limit 1) s on true
 where e.employee_no = '$1' \gset
set role authenticated;
$2
SQL
}
rows() { # $1=前綴 $2=筆數
  q -c "select jsonb_agg(jsonb_build_object('row', i + 1, 'code', 'CC-' || i, 'name', '$1' || i, 'spec', '')) from generate_series(1, $2) i"
}
before=$(q -c "select version from public.product_master_state")
A=$(as_user TEST006 "select public.admin_product_import_preview('A.xlsx', null, '[\"產品代碼\",\"品名\",\"規格\"]', '$(rows 甲 50)')->>'batch_id';" | tail -1)
B=$(as_user TEST008 "select public.admin_product_import_preview('B.xlsx', null, '[\"產品代碼\",\"品名\",\"規格\"]', '$(rows 乙 50)')->>'batch_id';" | tail -1)

# 第三個連線先持有匯入鎖 2 秒，讓兩個同步請求確實同時排隊
q -c "select pg_advisory_lock(hashtext('sucoot.product_master_import')); select pg_sleep(2); select pg_advisory_unlock(hashtext('sucoot.product_master_import'));" >/dev/null &
holder=$!
sleep 0.5
outA=$(mktemp); outB=$(mktemp)
(as_user TEST006 "select public.admin_product_import_commit('$A', true)->>'status';" >"$outA" 2>&1 || true) &
(as_user TEST008 "select public.admin_product_import_commit('$B', true)->>'status';" >"$outB" 2>&1 || true) &
wait
ra=$(grep -m1 -oE "COMMITTED|ERROR: +[A-Z_]+" "$outA" || cat "$outA"); rb=$(grep -m1 -oE "COMMITTED|ERROR: +[A-Z_]+" "$outB" || cat "$outB"); rm -f "$outA" "$outB"
after=$(q -c "select version from public.product_master_state")
names=$(q -c "select string_agg(distinct left(name, 1), '') from public.products where code like 'CC-%' and is_active")
echo "管理員 A：$ra"
echo "管理員 B：$rb"
echo "主檔版本：$before → $after；CC-* 品名前綴：$names"
ok=0
{ [[ "$ra" == COMMITTED && "$rb" == *STALE_PREVIEW* ]] || [[ "$rb" == COMMITTED && "$ra" == *STALE_PREVIEW* ]]; } && ok=$((ok + 1))
[[ "$after" == $((before + 1)) ]] && ok=$((ok + 1))
[[ "$names" == 甲 || "$names" == 乙 ]] && ok=$((ok + 1))
if [[ $ok == 3 ]]; then echo "PASS 並發匯入：恰好一位成功、另一位要求重新預覽、資料一致"; else echo "FAIL 並發匯入"; exit 1; fi
