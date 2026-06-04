#!/usr/bin/env bash
#===============================================================================
# remote-worker.sh — runs on the target instance to start a tcpux worker inside
#                    a dedicated tmux session:window:panes. Idempotent.
#===============================================================================
set -euo pipefail

INSTALL="${1:?install dir required}"
cd "$INSTALL"
set -o allexport; . ./.env; set +o allexport

: "${TCPUX_PORT:?set in deploy/.env}"

SESSION="${WORKER_SESSION:-tcpuxdo-worker}"
WINDOW="${WORKER_WINDOW:-worker}"
P_MAIN="${WORKER_PANE_MAIN:-tcpuxdo-worker-main}"
P_OBS="${WORKER_PANE_OBS:-tcpuxdo-worker-obs}"
NAME="${WORKER_NAME:-worker1}"
# Workers dial the queue locally (same host); never use the bind address.
HOST="127.0.0.1"
PORT="${TCPUX_PORT}"
PY="${PYTHON:-python3}"
SHELL_NAMES='^(bash|zsh|fish|sh|dash|tcsh|ksh)$'

say() { printf '  %s\n' "$*"; }

# ── 1. session ─────────────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$INSTALL"
    say "created session $SESSION"
else
    say "session $SESSION exists"
fi

# ── 2. window ──────────────────────────────────────────────────
if ! tmux list-windows -t "$SESSION" -F '#W' | grep -qx "$WINDOW"; then
    tmux new-window -t "$SESSION" -n "$WINDOW" -c "$INSTALL"
    say "created window $WINDOW"
else
    say "window $WINDOW exists"
fi

# ── 3. main pane (worker process) ──────────────────────────────
first_idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | head -1)
tmux select-pane -t "$SESSION:$WINDOW.$first_idx" -T "$P_MAIN"
cur=$(tmux display-message -p -t "$SESSION:$WINDOW.$first_idx" '#{pane_current_command}')
if [[ "$cur" =~ $SHELL_NAMES ]]; then
    tmux send-keys -t "$SESSION:$WINDOW.$first_idx" \
        "cd $INSTALL && set -o allexport && source .env && set +o allexport && $PY worker.py --name $NAME --host $HOST" Enter
    say "started worker in pane $P_MAIN"
else
    say "pane $P_MAIN busy ($cur) — leaving alone"
fi

# ── 4. obs pane (live tmux pane dump) ─────────────────────────
have_obs=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_OBS" || true)
if [[ "$have_obs" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$INSTALL"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_OBS"
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "while sleep 3; do clear; echo '== $(date) =='; tmux list-panes -a -F '#{session_name}:#{window_index}:#{pane_index}  #{pane_current_command}  #{pane_title}'; done" Enter
    say "started pane observer in $P_OBS"
else
    say "obs pane $P_OBS already exists"
fi

# ── 5. report ─────────────────────────────────────────────────
echo
echo "worker @ $SESSION:$WINDOW  (name=$NAME → $HOST:$PORT)"
tmux list-panes -t "$SESSION:$WINDOW" \
    -F '  pane #{pane_index}  title=#{pane_title}  cmd=#{pane_current_command}'
