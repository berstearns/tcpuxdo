#!/usr/bin/env bash
#===============================================================================
# node-redeploy.sh — fire a pinned update + worker respawn on a tty node THROUGH the
# relay. Nodes have no inbound ssh, so we can't use the relay-attach.sh "stage,
# then press Enter" trick here — the queue auto-appends Enter, so this RUNS
# immediately. The git pull happens ON the node; worker-restart.sh respawns it.
#
#   node-redeploy.sh [WORKER] [CTL_PANE] [NODE_ROOT] FULL_SHA
#   node-redeploy.sh --adopt-default BRANCH [WORKER] [CTL_PANE] [NODE_ROOT]
#   defaults: cros-penguin   tcpuxdo-worker:1:3   ~/tcpuxdo
#
# For the laptop-side "ready to press Enter" feel, a tmuxinator pane stages this
# with zsh:  print -z 'bash setup/node-redeploy.sh'  (see tcpuxdo-main.yml).
#===============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
MODE=pinned
if [[ "${1:-}" == --adopt-default ]]; then
  MODE=adopt; shift
  BRANCH="${1:-}"; shift || true
  [[ "$BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo 'adoption requires an explicit default branch name' >&2; exit 2; }
fi
W="${1:-cros-penguin}"
CTL="${2:-${TCPUX_NODE_CTL:-tcpuxdo-worker:1:3}}"
NROOT="${3:-${TCPUX_NODE_ROOT:-~/tcpuxdo}}"
SHA="${4:-${REDEPLOY_SHA:-}}"
if [[ "$MODE" == pinned ]]; then
  [[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'supply the master-resolved full SHA as argument 4 or REDEPLOY_SHA' >&2; exit 2; }
fi
case "$NROOT" in
  '~/'*) suffix="${NROOT#\~/}"; [[ "$suffix" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo 'NODE_ROOT after ~/ may contain only letters, digits, dot, underscore, slash, and dash' >&2; exit 2; }; REMOTE_ROOT="~/'$suffix'" ;;
  /*) [[ "$NROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo 'absolute NODE_ROOT may contain only letters, digits, dot, underscore, slash, and dash' >&2; exit 2; }; printf -v REMOTE_ROOT '%q' "$NROOT" ;;
  *) echo 'NODE_ROOT must be ~/relative/path or an absolute path on the worker' >&2; exit 2 ;;
esac

echo "→ firing redeploy on '$W' (ctl pane $CTL, repo $NROOT) through the relay"
if [[ "$MODE" == adopt ]]; then
  CMD="REDEPLOY_BRANCH='$BRANCH' bash $REMOTE_ROOT/setup/redeploy-watch.sh"
  echo "adoption: dispatching only tracked setup/redeploy-watch.sh for '$BRANCH'"
else
  CMD="cd $REMOTE_ROOT && REDEPLOY_ROLE=worker REDEPLOY_SHA='$SHA' bash setup/redeploy-watch.sh"
fi
exec ./tcpuxdo -w "$W" -p "$CTL" -c "$CMD"
