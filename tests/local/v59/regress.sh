#!/usr/bin/env bash
# 差異式回歸：對指定程式版本（REPO）重建隔離資料庫並執行 V5.8 既有測試。用法：regress.sh <repo 目錄> <標籤>
set -uo pipefail
REPO="$1"; TAG="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="${OUT:-$HERE/.out}"; mkdir -p "$OUT"
export PGHOST=/var/lib/postgresql/sucoot-v59/run PGPORT=54330 PGUSER=postgres PGDATABASE=postgres
REPO="$REPO" "$HERE/setup.sh" | tail -1
echo "[$TAG] migrations: $(ls "$REPO"/supabase/migrations/*.sql | wc -l)"
# 本機測試密碼（僅隔離資料庫）
accounts="$OUT/accounts.json"; echo '{}' > "$accounts"
for who in TEST001 TEST003 TEST004 TEST005 TEST006 TEST008 admin; do
  psql -qtAc "update auth.users set encrypted_password = extensions.crypt('LocalTest#2026', extensions.gen_salt('bf', 4)) where email = lower('$who') || '@login.sucoot.com'"
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); d[sys.argv[2]]='LocalTest#2026'; json.dump(d,open(sys.argv[1],'w'))" "$accounts" "$who"
done
pkill -f "node bridge.mjs" 2>/dev/null; sleep 0.5
(cd "$HERE/bridge" && nohup node bridge.mjs > "$OUT/bridge.log" 2>&1 < /dev/null & disown) > /dev/null 2>&1; sleep 1
for f in fix1 fix2 fix3 fix4 fix5 fix6 p4_recovery personal_security_notices; do
  if psql -q -v ON_ERROR_STOP=1 -f "$REPO/tests/local/$f.sql" >/dev/null 2>"$OUT/err.txt"; then echo "[$TAG] PASS $f"; else echo "[$TAG] FAIL $f: $(grep -m1 ERROR "$OUT/err.txt")"; fi
done
if SUCOOT_LOCAL_ACCOUNTS="$accounts" python3 -I "$REPO/tests/local/business_operations.py" > "$OUT/bo.txt" 2>&1; then
  echo "[$TAG] PASS business_operations.py ($(tail -1 "$OUT/bo.txt"))"
else
  echo "[$TAG] FAIL business_operations.py: $(tail -3 "$OUT/bo.txt" | tr '\n' ' ')"
fi
