#!/usr/bin/env bash
# 建立全新的隔離資料庫：PG16 + Supabase shim + repo 內全部 migrations + 合成組織
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; D=/var/lib/postgresql/sucoot-v59; REPO="${REPO:-$(cd "$S/../../.." && pwd)}"; BIN=/usr/lib/postgresql/16/bin
export PGHOST="$D/run" PGPORT=54330 PGUSER=postgres PGDATABASE=postgres
[ -f "$D/data/postmaster.pid" ] && su postgres -s /bin/bash -c "$BIN/pg_ctl -D $D/data -m fast stop" >/dev/null || true
rm -rf "$D"; mkdir -p "$D/run"; chown -R postgres:postgres "$D"
run() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
run "$BIN/initdb -D '$D/data' -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$BIN/pg_ctl -D '$D/data' -o \"-k '$D/run' -p 54330 -c listen_addresses='' -c timezone=UTC -c max_connections=60\" -l '$D/pg.log' -w start >/dev/null"
psql -q -v ON_ERROR_STOP=1 -f "$S/shim.sql" >/dev/null
for f in "$REPO"/supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 --single-transaction -f "$f" >/dev/null 2>"$S/last.err" || { echo "FAILED: $(basename "$f")"; cat "$S/last.err"; exit 1; }
  echo "applied $(basename "$f")"
done
psql -q -v ON_ERROR_STOP=1 -f "$S/fixture.sql" >/dev/null
echo "ready: $(psql -tAc 'select count(*) from public.employees') employees"
