#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
network=sucoot-v58-local
docker_local=(docker -H unix:///var/run/docker.sock)
[[ "$("${docker_local[@]}" network inspect -f '{{.Internal}}' "$network")" == true ]]
for role in db kong auth rest; do
  container="supabase_${role}_${network}"
  [[ "$("${docker_local[@]}" inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$container")" == "$network" ]]
done
python3 scripts/local-api.py &
bridge=$!
trap 'kill "$bridge" 2>/dev/null || true' EXIT
for _ in {1..20}; do
  kill -0 "$bridge" || exit 1
  if curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:54329/auth/v1/health >/dev/null; then break; fi
  sleep 0.2
done
kill -0 "$bridge"
npm run dev -- --host 127.0.0.1 --port 5173 --strictPort
