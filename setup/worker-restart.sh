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

pane=$(tmux list-panes -t "$SESSION" -a -F '#{window_index}.#{pane_index} #{pane_title}' 2>/dev/null \
        | awk -v t="$WORKER_TITLE" 'index($0,t){print $1; exit}')
[ -n "$pane" ] || { echo "worker pane '$WORKER_TITLE' not found in session '$SESSION'"; exit 1; }

echo "respawning $SESSION:$pane ($WORKER_TITLE) → relay $HOST:$PORT as '$NAME' from $ROOT …"
tmux respawn-pane -k -t "$SESSION:$pane" \
  "cd $ROOT && set -a && . ./.env && set +a && exec $PY worker.py --name $NAME --host $HOST --port $PORT"
sleep 2
echo "── worker pane after respawn ──────────────────────────────"
tmux capture-pane -p -t "$SESSION:$pane" | tail -10
