#!/usr/bin/env bash
# Ship the engine to the relay VPS and start the queue server inside a titled
# tmux session:window:panes (server / admin / state). Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

say "Sync engine → $VPS_SSH:$REMOTE_ROOT"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" "mkdir -p $REMOTE_ROOT"
for f in "${ENGINE[@]}"; do
  scp "${SSH_OPTS[@]}" "$REPO_ROOT/$f" "$VPS_SSH:$REMOTE_ROOT/$f"
done
# Ship the remote launcher + a relay-scoped .env (host=0.0.0.0 to bind all ifaces).
scp "${SSH_OPTS[@]}" "$REPO_ROOT/setup/remote-queue.sh" "$VPS_SSH:$REMOTE_ROOT/remote-queue.sh"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" "cat > $REMOTE_ROOT/.env" <<EOF
TCPUX_HOST=0.0.0.0
TCPUX_PORT=${PORT}
TCPUX_ADMIN_PORT=${ADMIN_PORT:?set TCPUX_ADMIN_PORT in .env}
TCPUX_ADMIN_TOKEN=${TCPUX_ADMIN_TOKEN:?set TCPUX_ADMIN_TOKEN in .env}
TCPUX_ALLOWLIST_DB=${TCPUX_ALLOWLIST_DB:-$REMOTE_ROOT/allowlist.json}
TCPUX_SHORTCUTS_DB=${TCPUX_SHORTCUTS_DB:-$REMOTE_ROOT/shortcuts.json}
QUEUE_SESSION=${QUEUE_SESSION:-tcpuxdo-queue}
QUEUE_WINDOW=${QUEUE_WINDOW:-queue}
QUEUE_PANE_SERVER=${QUEUE_PANE_SERVER:-tcpuxdo-queue-server}
QUEUE_PANE_ADMIN=${QUEUE_PANE_ADMIN:-tcpuxdo-queue-admin}
QUEUE_PANE_STATE=${QUEUE_PANE_STATE:-tcpuxdo-queue-state}
PYTHON=python3
EOF

say "Start queue in titled panes (remote-queue.sh)"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" "bash $REMOTE_ROOT/remote-queue.sh $REMOTE_ROOT"

echo "RELAY_DEPLOY_DONE — now run setup/02-open-ports.sh"
