#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
for tool in docker curl awk sort uniq; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done
docker compose version >/dev/null
URL="http://127.0.0.1:${LOCAL_PORT:-8080}"
STATS="http://127.0.0.1:${LOCAL_STATS_PORT:-8404}"
compose() { docker compose -f compose.yaml "$@"; }
confirm() {
  if [[ "${2:-}" != --yes ]]; then
    printf '%s Type yes to confirm: ' "$1"
    read -r answer
    [[ "$answer" == yes ]] || { echo 'Cancelled.'; exit 1; }
  fi
}
ready() {
  local i count
  for ((i=0; i<60; i++)); do
    count=$(curl -fsS --max-time 3 "$STATS/;csv" 2>/dev/null | tr -d '\r' | awk -F, '$1=="apps" && ($2=="app1" || $2=="app2") && $18=="UP" {n++} END {print n+0}') || count=0
    if [[ "$count" == 2 ]] && curl -fsS --max-time 3 "$URL" >/dev/null; then
      echo "Ready: two healthy backends. URL: $URL"
      return
    fi
    sleep 2
  done
  echo 'Readiness timed out. Run local/demo.sh status or docker compose -f local/compose.yaml logs.' >&2
  return 1
}
down() {
  local i state
  for ((i=0; i<40; i++)); do
    state=$(curl -fsS --max-time 3 "$STATS/;csv" 2>/dev/null | awk -F, -v s="$1" '$1=="apps" && $2==s {print $18}') || state=''
    case "$state" in
      DOWN*|MAINT*|NOLB*) printf 'Load balancer marked %s: %s\n' "$1" "$state"; return ;;
    esac
    sleep 1
  done
  echo "Timed out waiting for the load balancer to mark $1 down." >&2
  return 1
}
requests() {
  local i body backend identities=''
  for ((i=1; i<=20; i++)); do
    body=$(curl -fsS --http1.1 -H 'Connection: close' --connect-timeout 3 --max-time 5 "$URL")
    backend=$(printf '%s\n' "$body" | tr -d '\r' | sed -n 's/.*<h2>Served by: \([^<]*\)<\/h2>.*/\1/p')
    [[ -n "$backend" ]] || { echo 'Missing backend identity' >&2; return 1; }
    printf 'Request %02d -> %s\n' "$i" "$backend"
    identities+="$backend"$'\n'
    sleep 0.3
  done
  printf '\nBackend request counts:\n'
  printf '%s' "$identities" | sort | uniq -c
  local count
  count=$(printf '%s' "$identities" | sort -u | wc -l | tr -d ' ')
  printf 'Unique backends observed: %s\n' "$count"
  ((count >= 2)) || echo 'WARNING: only one backend observed; inspect status and retry.'
}
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: local/demo.sh setup|status|demo|self-heal|failover|destroy [--yes]' >&2; exit 2; }
[[ $# == 1 || ( "$2" == --yes && ( "$1" == failover || "$1" == self-heal || "$1" == destroy ) ) ]] || exit 2
case "$1" in
  setup)
    compose up -d --wait --wait-timeout 180
    ready
    echo "Health dashboard: $STATS"
    ;;
  status)
    compose ps -a
    printf '\nURL: %s\nHealth dashboard: %s\n' "$URL" "$STATS"
    curl -fsS --max-time 5 "$STATS/;csv" | tr -d '\r' | awk -F, '$1=="apps" && ($2=="app1" || $2=="app2") {print $2 ": " $18}'
    ;;
  demo) requests ;;
  self-heal)
    ready
    victim=$(compose ps -q app1)
    [[ -n "$victim" ]] || exit 1
    confirm "Terminate Apache inside app1 ($victim) to demonstrate automatic restart?" "${2:-}"
    # Docker restart policies become active after a successful 10-second run.
    sleep 11
    before=$(docker inspect --format '{{.RestartCount}}' "$victim")
    docker exec "$victim" sh -c 'kill -TERM 1'
    recovered=false
    for ((i=0; i<60; i++)); do
      after=$(docker inspect --format '{{.RestartCount}}' "$victim")
      if ((after > before)); then recovered=true; break; fi
      sleep 2
    done
    [[ "$recovered" == true ]] || { echo 'Automatic restart was not observed.' >&2; exit 1; }
    ready
    printf 'Automatic recovery: same container %s; restart count %s -> %s\n' "$victim" "$before" "$after"
    requests
    ;;
  failover)
    ready
    old=$(compose ps -q app1)
    [[ -n "$old" ]] || exit 1
    confirm "Stop and recreate app1 ($old)?" "${2:-}"
    compose stop app1
    echo 'app1 stopped; waiting for the load balancer to mark it down.'
    down app1
    requests
    echo 'Compose does not replace stopped containers automatically. Recreating app1 explicitly...'
    compose up -d --no-deps --force-recreate --wait --wait-timeout 120 app1
    new=$(compose ps -q app1)
    [[ -n "$new" && "$new" != "$old" ]] || { echo 'Replacement not confirmed' >&2; exit 1; }
    ready
    printf 'Old container: %s\nReplacement: %s\n' "$old" "$new"
    requests
    ;;
  destroy)
    compose ps -a
    confirm 'Remove only the aws-class-demo-local Compose containers and network?' "${2:-}"
    compose down --timeout 15
    remaining=$(docker ps -aq --filter label=com.docker.compose.project=aws-class-demo-local)
    networks=$(docker network ls -q --filter label=com.docker.compose.project=aws-class-demo-local)
    [[ -z "$remaining" && -z "$networks" ]] || { echo 'WARNING: local cleanup incomplete.' >&2; exit 1; }
    echo 'Local cleanup complete. Downloaded images remain cached; AWS resources are unaffected.'
    ;;
  *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
