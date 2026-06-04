#!/usr/bin/env bash
# Discover the relay state before deploying: SSH reachability, remote deps
# (python3, tmux), any existing tcpuxdo install, and the host firewall.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

say "SSH reachability ($VPS_SSH)"
if ssh "${SSH_OPTS[@]}" "$VPS_SSH" 'echo SSH_OK; uname -sr; id -un'; then
  echo "ssh: OK"
else
  echo "ssh: FAILED — fix key/agent auth before deploying"
fi

say "Relay deps (python3 tmux)"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" 'for c in python3 tmux; do command -v $c >/dev/null && echo "ok   $c" || echo "MISS $c"; done' || true

say "Existing tcpuxdo install on relay"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" "ls -ld $REMOTE_ROOT 2>/dev/null && tmux has-session -t ${QUEUE_SESSION:-tcpuxdo-queue} 2>/dev/null && echo 'queue session present' || echo 'no queue session'" || echo "no existing install"

say "Host firewall (ufw)"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" 'command -v ufw >/dev/null && ufw status 2>/dev/null | head -20 || echo "ufw: not installed/inactive"' || true

if [ -n "${NODE_SSH:-}" ]; then
  say "Node reachability + deps ($NODE_SSH)"
  ssh "${SSH_OPTS[@]}" "$NODE_SSH" 'echo NODE_OK; for c in python3 tmux; do command -v $c >/dev/null && echo "ok $c" || echo "MISS $c"; done' || echo "node ssh FAILED"
fi

echo "PREFLIGHT_DONE"
