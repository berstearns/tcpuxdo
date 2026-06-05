#!/usr/bin/env bash
# Discover the relay state before deploying: SSH reachability, remote deps
# (python3, tmux), any existing tcpuxdo install, and the host firewall.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

say "SSH reachability ($VPS_SSH)"
if RSSH 'echo SSH_OK; uname -sr; id -un'; then
  echo "ssh: OK"
else
  echo "ssh: FAILED — fix key/agent auth before deploying"
fi

say "Relay deps (python3 tmux)"
RSSH 'for c in python3 tmux; do command -v $c >/dev/null && echo "ok   $c" || echo "MISS $c"; done' || true

say "Existing tcpuxdo install on relay"
RSSH "ls -ld $REMOTE_ROOT 2>/dev/null && tmux has-session -t ${QUEUE_SESSION:-tcpuxdo-queue} 2>/dev/null && echo 'queue session present' || echo 'no queue session'" || echo "no existing install"

say "Host firewall (ufw)"
RSSH 'command -v ufw >/dev/null && ufw status 2>/dev/null | head -20 || echo "ufw: not installed/inactive"' || true

# (Nodes are not checked here — they are brought up on the node itself with
#  setup/node-up.sh, not deployed over SSH from main.)
echo "PREFLIGHT_DONE"
