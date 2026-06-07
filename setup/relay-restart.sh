#!/usr/bin/env bash
#===============================================================================
# relay-restart.sh — restart ONLY the tcpuxdo queue server pane in place, so it
# reloads server.py after a code ship. Run ON the relay.
#
# The scp-deploy path (01-relay-deploy.sh) ships fresh engine files but
# relay-up.sh deliberately leaves a running server pane alone — so after a ship
# the process is still executing the OLD code in memory. This is the missing
# "reload" step: Ctrl-C the server pane and re-launch server.py in it.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"
WINDOW="${QUEUE_WINDOW:-queue}"
SERVER_TITLE="${QUEUE_PANE_SERVER:-tcpuxdo-queue-server}"

pane=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index} #{pane_title}' \
        | awk -v t="$SERVER_TITLE" 'index($0,t){print $1; exit}')
pane="${pane:-0}"

echo "restarting server pane $SESSION:$WINDOW.$pane ($SERVER_TITLE)…"
tmux send-keys -t "$SESSION:$WINDOW.$pane" C-c
sleep 1
tmux send-keys -t "$SESSION:$WINDOW.$pane" \
  "cd $ROOT && set -o allexport && . ./.env && set +o allexport && python3 server.py" Enter
sleep 2
echo "── recent server pane output ──────────────────────────────"
tmux capture-pane -p -t "$SESSION:$WINDOW.$pane" | tail -10
