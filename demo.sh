#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
[[ $# == 0 ]] || { echo 'Usage: ./demo.sh (self-healing: ./failover-demo.sh)' >&2; exit 2; }
require_commands terraform curl python3
URL=$(terraform output -raw demo_url)
identities=$(mktemp)
trap 'rm -f -- "$identities"' EXIT
for ((i=1; i<=20; i++)); do
  # Separate curl processes, HTTP/1.1, no cookie jar, and Connection: close.
  body=$(curl --fail --silent --show-error --http1.1 -H 'Connection: close' \
    --connect-timeout 5 --max-time 15 "$URL")
  backend=$(printf '%s' "$body" | python3 -c '
import re, sys
match = re.search(r"<h2>Served by: ([^<]+)</h2>", sys.stdin.read())
if not match: sys.exit("Response did not contain a backend identity")
print(match[1].strip())
')
  printf 'Request %02d -> %s\n' "$i" "$backend"
  printf '%s\n' "$backend" >> "$identities"
  sleep 0.3
done
printf '\nObserved backends (request counts):\n'
sort "$identities" | uniq -c
unique=$(sort -u "$identities" | wc -l | tr -d ' ')
printf '\nUnique backends observed: %s\n' "$unique"
if ((unique < 2)); then
  echo 'WARNING: multiple backends were not observed. Check ./status.sh and retry; request order is not guaranteed.' >&2
fi
