#!/usr/bin/env bash
#===============================================================================
# redeploy-loop.sh — deprecated manual loop wrapper. It is NOT installed or
# started by node-up.sh/watchdog.sh. Pinned REDEPLOY_SHA is required each run;
# without it each cycle reports a configuration error and performs no update.
#
# Do not run unattended: REDEPLOY_SHA must be supplied for every invocation,
# and this loop does not obtain a new desired SHA from master.
#===============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
INT="${REDEPLOY_INTERVAL:-300}"
cli="$(basename "$ROOT")"

echo "redeploy-loop: legacy wrapper for $cli ($ROOT) every ${INT}s — no desired SHA is selected here"
while :; do
  out="$(bash setup/redeploy-watch.sh 2>&1)" || true
  [ -n "$out" ] && printf '\n%s\n' "$out"
  printf '\r[%(%Y-%m-%d %H:%M:%S)T] %s checked — next check %ss   ' -1 "$cli" "$INT"
  sleep "$INT"
done
