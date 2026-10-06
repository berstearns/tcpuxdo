#!/usr/bin/env bash
#===============================================================================
# relay-restart.sh — reload the tcpuxdo queue server in place after a code pull,
# by respawning ONLY the server pane. Run ON the relay (cwd = the live repo).
#
# `respawn-pane -k` atomically replaces the pane's process — the same move the
# relay's own redeploy history uses — so there is no C-c/re-run race and the
# port is reclaimed cleanly. The pane is found by title across the whole
# session, so it works regardless of which window holds it.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"
SERVER_TITLE="${QUEUE_PANE_SERVER:-tcpuxdo-queue-server}"

mapfile -t panes < <(tmux list-panes -t "$SESSION" -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
        | awk -v t="$SERVER_TITLE" '$2==t{print $1}')
[[ ${#panes[@]} -eq 1 ]] || { echo "expected exactly one server pane '$SERVER_TITLE' in '$SESSION', found ${#panes[@]}"; exit 1; }
pane="${panes[0]}"

echo "respawning $SESSION:$pane ($SERVER_TITLE) from $ROOT …"
tmux respawn-pane -k -t "$pane" \
  "cd '$ROOT' && set -a && . ./.env && set +a && exec python3 server.py"
sleep 2
echo "── server pane after respawn ──────────────────────────────"
tmux capture-pane -p -t "$SESSION:$pane" | tail -10
