#!/usr/bin/env bash
#===============================================================================
# relay-attach.sh — THE TRICK (laptop side): open the DO relay's tmux session in
# THIS pane over ssh, with the end-to-end redeploy command PRE-STAGED (typed,
# not run) in its 'redeploy' window. You just press Enter there.
#
# Chain:  sshpass + ssh -tt  →  relay-redeploy-attach.sh (on the relay), which:
#   1. tmux send-keys -t tcpuxdo-queue:redeploy -l "<cmd>"   ← stage, NO Enter
#   2. tmux select-window … ; exec tmux attach                ← so you SEE it
# So the keystrokes are written into a specific remote pane, ready to fire.
#
# Built to be a tmuxinator pane command:  `bash setup/relay-attach.sh`
# Reads connection from .env (TCPUX_HOST, TCPUX_VPS_USER); pass file ~/.do-pass.
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }

HOST="${TCPUX_HOST:?set TCPUX_HOST in .env}"
USER_="${TCPUX_VPS_USER:-root}"
REMOTE_ROOT="${TCPUX_REMOTE_ROOT:-/opt/tcpuxdo}"
PASS="${DO_PASS_FILE:-$HOME/.do-pass}"
REMOTE="bash $REMOTE_ROOT/setup/relay-redeploy-attach.sh"
SSH_OPTS=(-tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)

echo "relay-attach → $USER_@$HOST : $REMOTE_ROOT  (staging redeploy, then attaching)…"
if [ -f "$PASS" ] && command -v sshpass >/dev/null; then
  exec sshpass -f "$PASS" ssh "${SSH_OPTS[@]}" "$USER_@$HOST" "$REMOTE"
else
  exec ssh "${SSH_OPTS[@]}" "$USER_@$HOST" "$REMOTE"
fi
