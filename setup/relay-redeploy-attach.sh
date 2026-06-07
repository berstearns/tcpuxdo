#!/usr/bin/env bash
#===============================================================================
# relay-redeploy-attach.sh — open the relay's queue tmux with the server-restart
# command PRE-STAGED (typed into a 'redeploy' window, but NOT executed), then
# attach. Run ON the relay over `ssh -t` from main.
#
# You land in the redeploy window looking at:
#     bash /srv/tcpuxdo/setup/relay-restart.sh
# Review it, press Enter to reload server.py. Nothing fires on its own.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"

tmux has-session -t "$SESSION" 2>/dev/null || { echo "no '$SESSION' tmux session on relay"; exit 1; }
tmux list-windows -t "$SESSION" -F '#W' | grep -qx redeploy \
  || tmux new-window -t "$SESSION" -n redeploy -c "$ROOT"

# Stage (literal text, no Enter) — the human pulls the trigger.
tmux send-keys -t "$SESSION:redeploy" -l "bash $ROOT/setup/relay-restart.sh"
tmux select-window -t "$SESSION:redeploy"
exec tmux attach -t "$SESSION"
