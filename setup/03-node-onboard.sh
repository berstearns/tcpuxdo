#!/usr/bin/env bash
# Onboard ONE tty node: ship the engine, write a node-scoped .env (dials the
# relay), optionally provision a non-root RUN_USER (for Claude Code), and start
# a worker inside a titled tmux pane. Idempotent. Run once per node.
#
#   NODE_SSH=user@nodeA NODE_ROOT=/home/claude/tcpuxdo RUN_USER=claude \
#   TCPUX_WORKER=nodeA  bash setup/03-node-onboard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

: "${NODE_SSH:?set NODE_SSH=user@host in .env or the command}"
NODE_ROOT="${NODE_ROOT:-/home/${RUN_USER:-$(echo "$NODE_SSH" | cut -d@ -f1)}/tcpuxdo}"
WNAME="${TCPUX_WORKER:?set TCPUX_WORKER (unique per node) in .env or the command}"

say "Sync engine → $NODE_SSH:$NODE_ROOT"
ssh "${SSH_OPTS[@]}" "$NODE_SSH" "mkdir -p $NODE_ROOT"
for f in "${ENGINE[@]}"; do
  scp "${SSH_OPTS[@]}" "$REPO_ROOT/$f" "$NODE_SSH:$NODE_ROOT/$f"
done
scp "${SSH_OPTS[@]}" "$REPO_ROOT/setup/remote-worker.sh" "$NODE_SSH:$NODE_ROOT/remote-worker.sh"

say "Write node .env (dials relay $VPS_HOST:$PORT)"
ssh "${SSH_OPTS[@]}" "$NODE_SSH" "cat > $NODE_ROOT/.env" <<EOF
TCPUX_HOST=${VPS_HOST}
TCPUX_PORT=${PORT}
TCPUX_WORKER=${WNAME}
TCPUX_POLL=${TCPUX_POLL:-2}
TCPUX_SYNC=${TCPUX_SYNC:-5}
TCPUX_IDLE_CMDS=${TCPUX_IDLE_CMDS:-bash,zsh,fish,sh,dash,tcsh,ksh,claude}
WORKER_SESSION=${WORKER_SESSION:-tcpuxdo-worker}
WORKER_WINDOW=${WORKER_WINDOW:-worker}
WORKER_PANE_MAIN=${WORKER_PANE_MAIN:-tcpuxdo-worker-main}
WORKER_PANE_OBS=${WORKER_PANE_OBS:-tcpuxdo-worker-obs}
PYTHON=python3
EOF

say "Start worker in a titled pane (remote-worker.sh)"
ssh "${SSH_OPTS[@]}" "$NODE_SSH" "bash $NODE_ROOT/remote-worker.sh $NODE_ROOT"

echo
echo "NODE_ONBOARD_DONE — worker '$WNAME' should now be polling the relay."
echo "Confirm from main:  tcpuxdo list $WNAME"
