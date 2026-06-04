#!/usr/bin/env bash
#===============================================================================
# remote-queue.sh — runs on the target instance to start the tcpux queue server
#                   inside a dedicated tmux session:window:panes.
#
# Invoked by deploy.sh with a single arg: the install directory containing
# the unpacked tcpux source and the deploy .env. Idempotent.
#
# The dev-rule "every terminal command must run through a titled tmux pane"
# exempts the bootstrap calls below (new-session / new-window / split-window /
# pane-name send-keys). Everything that runs AFTER bootstrap lives inside the
# titled panes we create here.
#===============================================================================
set -euo pipefail

INSTALL="${1:?install dir required}"
cd "$INSTALL"
set -o allexport; . ./.env; set +o allexport

# All ports/paths come from .env. No hardcoded defaults.
: "${TCPUX_PORT:?set in deploy/.env}"
: "${TCPUX_ADMIN_PORT:?set in deploy/.env}"
: "${TCPUX_ADMIN_TOKEN:?set in deploy/.env}"
: "${TCPUX_ALLOWLIST_DB:?set in deploy/.env}"

SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"
WINDOW="${QUEUE_WINDOW:-queue}"
P_SERVER="${QUEUE_PANE_SERVER:-tcpuxdo-queue-server}"
P_STATE="${QUEUE_PANE_STATE:-tcpuxdo-queue-state}"
P_ADMIN="${QUEUE_PANE_ADMIN:-tcpuxdo-queue-admin}"
HOST="${TCPUX_HOST:-0.0.0.0}"
PORT="${TCPUX_PORT}"
ADMIN_PORT="${TCPUX_ADMIN_PORT}"
PY="${PYTHON:-python3}"

SHELL_NAMES='^(bash|zsh|fish|sh|dash|tcsh|ksh)$'

say() { printf '  %s\n' "$*"; }

# Seed the allowlist db from allowlist.seed.json if it does not exist yet.
# The db is the single source of truth once created; the seed is only used
# to bootstrap.
if [[ ! -f "$TCPUX_ALLOWLIST_DB" ]]; then
    mkdir -p "$(dirname "$TCPUX_ALLOWLIST_DB")"
    cp "$INSTALL/allowlist.seed.json" "$TCPUX_ALLOWLIST_DB"
    say "seeded allowlist db at $TCPUX_ALLOWLIST_DB"
else
    say "allowlist db at $TCPUX_ALLOWLIST_DB (leaving intact)"
fi

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

# ── 3. server pane (first pane of this window) ─────────────────
first_idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | head -1)
tmux select-pane -t "$SESSION:$WINDOW.$first_idx" -T "$P_SERVER"
cur=$(tmux display-message -p -t "$SESSION:$WINDOW.$first_idx" '#{pane_current_command}')
if [[ "$cur" =~ $SHELL_NAMES ]]; then
    tmux send-keys -t "$SESSION:$WINDOW.$first_idx" \
        "cd $INSTALL && set -o allexport && source .env && set +o allexport && $PY server.py" Enter
    say "started server in pane $P_SERVER"
else
    say "pane $P_SERVER busy ($cur) — leaving alone"
fi

# ── 4. admin (allowlist_server.py) pane ────────────────────────
have_admin=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_ADMIN" || true)
if [[ "$have_admin" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$INSTALL"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_ADMIN"
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "cd $INSTALL && set -o allexport && source .env && set +o allexport && $PY allowlist_server.py serve" Enter
    say "started allowlist admin in pane $P_ADMIN (port $ADMIN_PORT)"
else
    say "admin pane $P_ADMIN already exists"
fi

# ── 5. state pane (split if missing) ───────────────────────────
have_state=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_STATE" || true)
if [[ "$have_state" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$INSTALL"
    # index of the just-created pane = the last one
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_STATE"
    # wait 2s so the server has time to bind, then poll state.
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "cd $INSTALL && set -o allexport && source .env && set +o allexport && sleep 2 && while sleep 5; do $PY -c 'import os,json,sys; sys.path.insert(0,\".\"); from proto import rpc; print(json.dumps(rpc(\"127.0.0.1\",int(os.environ[\"TCPUX_PORT\"]),{\"op\":\"state\"}),indent=2,default=str)[:800]); print(\"---\")'; done" Enter
    say "started state tail in pane $P_STATE"
else
    say "state pane $P_STATE already exists"
fi

# ── 5. report ─────────────────────────────────────────────────
echo
echo "queue @ $SESSION:$WINDOW"
tmux list-panes -t "$SESSION:$WINDOW" \
    -F '  pane #{pane_index}  title=#{pane_title}  cmd=#{pane_current_command}'
