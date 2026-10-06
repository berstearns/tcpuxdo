#!/usr/bin/env bash
#===============================================================================
# worker-restart.sh — reload the tcpuxdo worker in place after a code pull, by
# respawning ONLY the worker pane. Run ON the node (the script lives in the repo).
#
# Mirrors relay-restart.sh, and closes the redeploy gap: node-up.sh deliberately
# leaves a RUNNING worker pane alone, so after a `git pull` the worker process is
# still executing the OLD worker.py. `respawn-pane -k` atomically replaces it,
# re-reading .env for name/host/port. The worker pane is found by title across
# the session, so window naming/index don't matter.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
set -o allexport; . ./.env; set +o allexport

SESSION="${WORKER_SESSION:-tcpuxdo-worker}"
WORKER_TITLE="${WORKER_PANE_MAIN:-tcpuxdo-worker-main}"
NAME="${TCPUX_WORKER:-$(hostname)}"
HOST="${TCPUX_HOST:?set TCPUX_HOST in .env}"
PORT="${TCPUX_PORT:?set TCPUX_PORT in .env}"
PY="${PYTHON:-python3}"

mapfile -t panes < <(tmux list-panes -t "$SESSION" -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
        | awk -v t="$WORKER_TITLE" '$2==t{print $1}')
[[ ${#panes[@]} -eq 1 ]] || { echo "expected exactly one worker pane '$WORKER_TITLE' in '$SESSION', found ${#panes[@]}"; exit 1; }
pane="${panes[0]}"

echo "respawning $SESSION:$pane ($WORKER_TITLE) → relay $HOST:$PORT as '$NAME' from $ROOT …"
tmux respawn-pane -k -t "$pane" \
  "cd '$ROOT' && set -a && . ./.env && set +a && exec '$PY' worker.py --name '$NAME' --host '$HOST' --port '$PORT'"
sleep 2
echo "── worker pane after respawn ──────────────────────────────"
tmux capture-pane -p -t "$SESSION:$pane" | tail -10
