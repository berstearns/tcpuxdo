#!/usr/bin/env bash
#===============================================================================
# redeploy-loop.sh — no-systemd auto-redeploy. Run redeploy-watch.sh forever in
# a tmux pane, every REDEPLOY_INTERVAL seconds. One pane per machine (relay,
# each tty node, main laptop). Ctrl-C to stop.
#
# redeploy-watch.sh is a quiet no-op when origin == HEAD; it only speaks (and
# git-pull + respawn the server/worker) when a new commit lands. So this pane
# stays silent except for a heartbeat line, and prints a block when it ships.
#
#   bash setup/redeploy-loop.sh                 # default 300s
#   REDEPLOY_INTERVAL=60 bash setup/redeploy-loop.sh
#===============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
INT="${REDEPLOY_INTERVAL:-300}"
cli="$(basename "$ROOT")"

echo "redeploy-loop: watching $cli ($ROOT) every ${INT}s — Ctrl-C to stop"
while :; do
  out="$(bash setup/redeploy-watch.sh 2>&1)" || true
  [ -n "$out" ] && printf '\n%s\n' "$out"
  printf '\r[%(%Y-%m-%d %H:%M:%S)T] %s up to date — next check %ss   ' -1 "$cli" "$INT"
  sleep "$INT"
done
