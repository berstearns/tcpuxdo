#!/usr/bin/env bash
# EXCEPTION PATH (relay only): deploy the relay FROM main over SSH instead of
# the default "git clone on the box + cp .env + bash setup/relay-up.sh". It
# ships this repo's engine + setup/relay-up.sh to the VPS, writes a relay .env,
# and runs setup/relay-up.sh remotely. Idempotent. (Nodes have no such path —
# they are always brought up locally with setup/node-up.sh.)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

say "Sync engine → $VPS_SSH:$REMOTE_ROOT  (transport: $TRANSPORT)"
RSSH "mkdir -p $REMOTE_ROOT/setup"
for f in "${ENGINE[@]}"; do
  RSCP "$REPO_ROOT/$f" "$VPS_SSH:$REMOTE_ROOT/$f"
done
# Ship the launcher into setup/ so relay-up.sh resolves ROOT=$REMOTE_ROOT.
RSCP "$REPO_ROOT/setup/relay-up.sh" "$VPS_SSH:$REMOTE_ROOT/setup/relay-up.sh"
RSSH "cat > $REMOTE_ROOT/.env" <<EOF
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

say "Start queue (runs setup/relay-up.sh on the relay — same script as the default path)"
RSSH "cd $REMOTE_ROOT && bash setup/relay-up.sh"

echo "RELAY_DEPLOY_DONE — now run setup/02-open-ports.sh"
