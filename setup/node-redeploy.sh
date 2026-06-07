#!/usr/bin/env bash
#===============================================================================
# node-redeploy.sh — fire a git pull + worker respawn on a tty node THROUGH the
# relay. Nodes have no inbound ssh, so we can't use the relay-attach.sh "stage,
# then press Enter" trick here — the queue auto-appends Enter, so this RUNS
# immediately. The git pull happens ON the node; worker-restart.sh respawns it.
#
#   node-redeploy.sh [WORKER] [CTL_PANE] [NODE_ROOT]
#   defaults: cros-penguin   tcpuxdo-worker:1:3   ~/tcpuxdo
#
# For the laptop-side "ready to press Enter" feel, a tmuxinator pane stages this
# with zsh:  print -z 'bash setup/node-redeploy.sh'  (see tcpuxdo-main.yml).
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
W="${1:-cros-penguin}"
CTL="${2:-${TCPUX_NODE_CTL:-tcpuxdo-worker:1:3}}"
NROOT="${3:-${TCPUX_NODE_ROOT:-~/tcpuxdo}}"

echo "→ firing redeploy on '$W' (ctl pane $CTL, repo $NROOT) through the relay"
exec ./tcpuxdo -w "$W" -p "$CTL" -c "cd $NROOT && git pull --ff-only && bash setup/worker-restart.sh"
