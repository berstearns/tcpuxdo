#!/usr/bin/env bash
#===============================================================================
# node-up.sh — run ON a tty node after `git clone` + `cp .env.example .env`.
# Starts a tcpuxdo worker inside a titled tmux session, polling the RELAY and
# executing tmux ops locally (send-keys into your panes, incl. a Claude pane).
# Idempotent. Reads .env from the repo root.
#
# This is the ONLY supported way to bring up a node. Nodes are deliberately NOT
# deployed over SSH from main — you clone here, set .env, run this. (Only the
# relay has an SSH-from-main convenience path; see setup/01-relay-deploy.sh.)
#===============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .env ] || { echo "missing $ROOT/.env — cp .env.example .env and set TCPUX_HOST=<relay-ip>, TCPUX_PORT, TCPUX_WORKER"; exit 1; }
set -o allexport; . ./.env; set +o allexport

: "${TCPUX_HOST:?set TCPUX_HOST=<relay-ip> in .env (the node dials the relay)}"
: "${TCPUX_PORT:?set TCPUX_PORT in .env}"

NAME="${TCPUX_WORKER:-$(hostname)}"   # unique per node; how main addresses it
HOST="${TCPUX_HOST}"                  # the RELAY — never 127.0.0.1 on a tty node
PORT="${TCPUX_PORT}"
PY="${PYTHON:-python3}"
SESSION="${WORKER_SESSION:-tcpuxdo-worker}"
WINDOW="${WORKER_WINDOW:-worker}"
P_MAIN="${WORKER_PANE_MAIN:-tcpuxdo-worker-main}"
P_OBS="${WORKER_PANE_OBS:-tcpuxdo-worker-obs}"
P_CTL="${WORKER_PANE_CTL:-tcpuxdo-worker-ctl}"
SHELL_NAMES='^(bash|zsh|fish|sh|dash|tcsh|ksh)$'
say() { printf '  %s\n' "$*"; }

# ── session / window ───────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$ROOT"; say "created session $SESSION"
else
    say "session $SESSION exists"
fi
tmux list-windows -t "$SESSION" -F '#W' | grep -qx "$WINDOW" || tmux new-window -t "$SESSION" -n "$WINDOW" -c "$ROOT"

# ── worker pane ────────────────────────────────────────────────
first_idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | head -1)
tmux select-pane -t "$SESSION:$WINDOW.$first_idx" -T "$P_MAIN"
cur=$(tmux display-message -p -t "$SESSION:$WINDOW.$first_idx" '#{pane_current_command}')
if [[ "$cur" =~ $SHELL_NAMES ]]; then
    tmux send-keys -t "$SESSION:$WINDOW.$first_idx" \
        "cd $ROOT && set -o allexport && source .env && set +o allexport && $PY worker.py --name $NAME --host $HOST --port $PORT" Enter
    say "started worker '$NAME' in pane $P_MAIN → $HOST:$PORT"
else
    say "pane $P_MAIN busy ($cur) — leaving alone"
fi

# ── obs pane (live pane dump) ──────────────────────────────────
if [[ "$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_OBS" || true)" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$ROOT"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_OBS"
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "while sleep 3; do clear; echo \"== \$(date) ==\"; tmux list-panes -a -F '#{session_name}:#{window_index}:#{pane_index}  #{pane_current_command}  #{pane_title}'; done" Enter
    say "started pane observer in $P_OBS"
else
    say "obs pane $P_OBS already exists"
fi

# ── ctl pane (idle shell — push-model redeploy target) ─────────
# Stays at a bare prompt so it counts as IDLE: main can `tcpuxdo -w $NAME
# -p $SESSION:$WINDOW:$P_CTL -c 'bash setup/redeploy-watch.sh'` to trigger an
# instant redeploy WITHOUT typing into the busy worker pane (which the idle-gate
# would reject). Steady-state redeploy is the systemd timer; this is the "now" button.
if [[ "$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_CTL" || true)" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$ROOT"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_CTL"
    tmux select-layout -t "$SESSION:$WINDOW" tiled >/dev/null 2>&1 || true
    say "created idle control pane $P_CTL (push-model redeploy target)"
else
    say "control pane $P_CTL already exists"
fi

echo
echo "worker '$NAME' @ $SESSION:$WINDOW  → relay $HOST:$PORT"
echo "instant redeploy from main:  tcpuxdo -w $NAME -p $SESSION:$WINDOW:$P_CTL -c 'bash setup/redeploy-watch.sh'"
echo "from main, allow this node's egress IP then address it:"
echo "  tcpuxdo allow \$(curl -s ifconfig.me)     # run anywhere with the admin token"
echo "  tcpuxdo list $NAME"
tmux list-panes -t "$SESSION:$WINDOW" -F '  pane #{pane_index}  title=#{pane_title}  cmd=#{pane_current_command}'
