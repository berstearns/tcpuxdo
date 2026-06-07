#!/usr/bin/env bash
#===============================================================================
# relay-redeploy-attach.sh — open the relay's queue tmux with the END-TO-END
# redeploy command PRE-STAGED (typed into a 'redeploy' window, but NOT executed),
# then attach. Run ON the relay over `ssh -t` from main.
#
# You land in the redeploy window looking at:
#     cd /opt/tcpuxdo && git pull --ff-only && bash setup/relay-restart.sh
# Review it, press Enter to pull latest + respawn the server. Nothing fires on
# its own.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"

tmux has-session -t "$SESSION" 2>/dev/null || { echo "no '$SESSION' tmux session on relay"; exit 1; }
tmux list-windows -t "$SESSION" -F '#W' | grep -qx redeploy \
  || tmux new-window -t "$SESSION" -n redeploy -c "$ROOT"

# Clear any half-typed line, then stage the end-to-end command (literal text,
# no Enter) — the human pulls the trigger.
tmux send-keys -t "$SESSION:redeploy" C-c
tmux send-keys -t "$SESSION:redeploy" -l "cd $ROOT && git pull --ff-only && bash setup/relay-restart.sh"
tmux select-window -t "$SESSION:redeploy"
exec tmux attach -t "$SESSION"
