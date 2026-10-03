#!/usr/bin/env bash
# WSL worker watchdog. The person at the WSL laptop runs exactly one command:
#   curl -fsSL https://raw.githubusercontent.com/berstearns/tcpuxdo/master/setup/windows/wsl-watch.sh | bash
# Leave that terminal open. Each pass downloads the latest copy of this script
# and the latest rescue from GitHub. Rescue updates the local checkout, repairs
# the worker, and verifies a fresh heartbeat with the relay. No admin token is
# needed on the node. A failed pass is retried until the link works.
set -uo pipefail

BASE=https://raw.githubusercontent.com/berstearns/tcpuxdo/master/setup/windows
INTERVAL="${WSL_WATCH_INTERVAL:-60}"
case "$INTERVAL" in *[!0-9]*|'') echo "WSL_WATCH_INTERVAL must be seconds" >&2; exit 64;; esac
[ "$INTERVAL" -gt 0 ] || { echo "WSL_WATCH_INTERVAL must be positive" >&2; exit 64; }

fetch() {
  curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 \
    -H 'Cache-Control: no-cache' "$1" -o "$2"
}

# The outer loop stays small and stable. This branch is re-downloaded on every
# pass, so a fix pushed to master is applied without asking anyone to retype.
if [ "${1:-}" = --once ]; then
  rescue="$(mktemp)" || exit 1
  if ! fetch "$BASE/wsl-rescue.sh" "$rescue"; then
    echo "Could not download latest rescue from GitHub; will retry." >&2
    rm -f "$rescue"
    exit 1
  fi
  log="${RESCUE_LOG_FILE:-$HOME/tcpuxdo-rescue-watch.log}"
  if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt 5242880 ]; then
    mv -f "$log" "$log.previous"
  fi
  RESCUE_LOG_FILE="$log" bash "$rescue"
  rc=$?
  rm -f "$rescue"
  exit "$rc"
fi

echo "WSL worker watch started. Leave this terminal open; it checks every ${INTERVAL}s."
echo "Latest details are saved in $HOME/tcpuxdo-rescue-watch.log"
while :; do
  latest="$(mktemp)" || exit 1
  if fetch "$BASE/wsl-watch.sh" "$latest"; then
    out="$(bash "$latest" --once 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s  worker connected; checking again in %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"
    else
      printf '%s\n' "$out"
      printf '%s  recovery failed (exit %s); retrying in %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$INTERVAL"
    fi
  else
    echo "GitHub unreachable; retrying in ${INTERVAL}s."
  fi
  rm -f "$latest"
  sleep "$INTERVAL"
done
