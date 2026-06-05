#!/usr/bin/env bash
#===============================================================================
# relay-up.sh — run ON the relay after `git clone` + `cp .env.example .env`.
# Starts the tcpuxdo queue (server + allowlist admin + state poller) inside a
# titled tmux session. Idempotent. Reads .env from the repo root.
#
# This is the DEFAULT relay bring-up: clone + .env + this one command.
# (The SSH-from-main path, setup/01-relay-deploy.sh, is a convenience exception
#  that ships this repo to the VPS and runs this same script remotely.)
#===============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .env ] || { echo "missing $ROOT/.env — cp .env.example .env and set TCPUX_PORT/ADMIN_PORT/TOKEN"; exit 1; }
set -o allexport; . ./.env; set +o allexport

: "${TCPUX_PORT:?set TCPUX_PORT in .env}"
: "${TCPUX_ADMIN_PORT:?set TCPUX_ADMIN_PORT in .env}"
: "${TCPUX_ADMIN_TOKEN:?set TCPUX_ADMIN_TOKEN in .env}"
TCPUX_ALLOWLIST_DB="${TCPUX_ALLOWLIST_DB:-$ROOT/allowlist.json}"
export TCPUX_ALLOWLIST_DB

SESSION="${QUEUE_SESSION:-tcpuxdo-queue}"
WINDOW="${QUEUE_WINDOW:-queue}"
P_SERVER="${QUEUE_PANE_SERVER:-tcpuxdo-queue-server}"
P_ADMIN="${QUEUE_PANE_ADMIN:-tcpuxdo-queue-admin}"
P_STATE="${QUEUE_PANE_STATE:-tcpuxdo-queue-state}"
ADMIN_PORT="${TCPUX_ADMIN_PORT}"
PY="${PYTHON:-python3}"
SHELL_NAMES='^(bash|zsh|fish|sh|dash|tcsh|ksh)$'
say() { printf '  %s\n' "$*"; }

# Seed the allowlist db from allowlist.seed.json on first run; it is the source
# of truth thereafter (the seed only bootstraps).
if [[ ! -f "$TCPUX_ALLOWLIST_DB" ]]; then
    mkdir -p "$(dirname "$TCPUX_ALLOWLIST_DB")"
    cp "$ROOT/allowlist.seed.json" "$TCPUX_ALLOWLIST_DB"
    say "seeded allowlist db at $TCPUX_ALLOWLIST_DB"
else
    say "allowlist db at $TCPUX_ALLOWLIST_DB (leaving intact)"
fi

# ── session / window ───────────────────────────────────────────
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$ROOT"; say "created session $SESSION"
else
    say "session $SESSION exists"
fi
tmux list-windows -t "$SESSION" -F '#W' | grep -qx "$WINDOW" || tmux new-window -t "$SESSION" -n "$WINDOW" -c "$ROOT"

# ── server pane ────────────────────────────────────────────────
first_idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | head -1)
tmux select-pane -t "$SESSION:$WINDOW.$first_idx" -T "$P_SERVER"
cur=$(tmux display-message -p -t "$SESSION:$WINDOW.$first_idx" '#{pane_current_command}')
if [[ "$cur" =~ $SHELL_NAMES ]]; then
    tmux send-keys -t "$SESSION:$WINDOW.$first_idx" \
        "cd $ROOT && set -o allexport && source .env && set +o allexport && $PY server.py" Enter
    say "started server in pane $P_SERVER"
else
    say "pane $P_SERVER busy ($cur) — leaving alone"
fi

# ── admin pane ─────────────────────────────────────────────────
if [[ "$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_ADMIN" || true)" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$ROOT"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_ADMIN"
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "cd $ROOT && set -o allexport && source .env && set +o allexport && $PY allowlist_server.py serve" Enter
    say "started allowlist admin in pane $P_ADMIN (port $ADMIN_PORT)"
else
    say "admin pane $P_ADMIN already exists"
fi

# ── state pane ─────────────────────────────────────────────────
if [[ "$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_title}' | grep -cx "$P_STATE" || true)" -eq 0 ]]; then
    tmux split-window -t "$SESSION:$WINDOW" -c "$ROOT"
    idx=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION:$WINDOW.$idx" -T "$P_STATE"
    tmux send-keys -t "$SESSION:$WINDOW.$idx" \
        "cd $ROOT && set -o allexport && source .env && set +o allexport && sleep 2 && while sleep 5; do $PY -c 'import os,json,sys; sys.path.insert(0,\".\"); from proto import rpc; print(json.dumps(rpc(\"127.0.0.1\",int(os.environ[\"TCPUX_PORT\"]),{\"op\":\"state\"}),indent=2,default=str)[:800]); print(\"---\")'; done" Enter
    say "started state tail in pane $P_STATE"
else
    say "state pane $P_STATE already exists"
fi

echo
echo "queue @ $SESSION:$WINDOW  (server :$TCPUX_PORT, admin :$ADMIN_PORT)"
tmux list-panes -t "$SESSION:$WINDOW" -F '  pane #{pane_index}  title=#{pane_title}  cmd=#{pane_current_command}'
