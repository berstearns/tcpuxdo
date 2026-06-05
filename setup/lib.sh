#!/usr/bin/env bash
# tcpuxdo setup — shared config + helpers. Sourced by the numbered setup scripts.
#
# Per the project rule, ALL command logic lives in these committed repo scripts;
# the real work is dispatched into a titled tmux pane on the target, never run
# ad-hoc. Real IPs / firewall IDs / node names stay out of the public repo —
# they live only in .env (see .env.example for the keys).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/.env" ] && { set -a; . "$REPO_ROOT/.env"; set +a; }

# Relay (VPS) coordinates — from .env (TCPUX_HOST), never hardcoded.
VPS_HOST="${VPS_HOST:-${TCPUX_HOST:-}}"
VPS_USER="${VPS_USER:-${TCPUX_VPS_USER:-root}}"
[ -n "$VPS_HOST" ] || { echo "lib.sh: TCPUX_HOST is unset — set it in $REPO_ROOT/.env" >&2; exit 1; }
VPS_SSH="$VPS_USER@$VPS_HOST"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# Relay transport. The DO droplet uses password auth via ~/.do-pass, so prefer
# the do-automation sshpass wrappers when present; fall back to key-auth ssh.
# RSSH "<remote cmd>"           runs the command on the relay (stdin passes through)
# RSCP <src> "$VPS_SSH:<dst>"   copies to the relay
DO_AUTO="${DO_AUTO:-$HOME/p/all-my-tiny-projects/do-automation}"
if [ -f "$HOME/.do-pass" ] && [ -x "$DO_AUTO/do-ssh-pass" ]; then
  RSSH(){ DO_HOST="$VPS_HOST" "$DO_AUTO/do-ssh-pass" "$@"; }
  RSCP(){ "$DO_AUTO/do-scp-pass" "$@"; }
  TRANSPORT="do-automation (sshpass via ~/.do-pass)"
else
  RSSH(){ ssh "${SSH_OPTS[@]}" "$VPS_SSH" "$@"; }
  RSCP(){ scp "${SSH_OPTS[@]}" "$@"; }
  TRANSPORT="ssh key-auth"
fi

PORT="${TCPUX_PORT:?set TCPUX_PORT in .env}"
ADMIN_PORT="${TCPUX_ADMIN_PORT:-}"
REMOTE_ROOT="${REMOTE_ROOT:-/srv/tcpuxdo}"

# Engine files shipped to relay + nodes (no .env, no secrets).
ENGINE=(server.py worker.py client.py axioms.py allowlist.py allowlist_server.py \
        proto.py allowlist.seed.json AXIOMS.md)

# DigitalOcean cloud firewall (optional) — id from env/.env for 02-open-ports.
DO_FW_ID="${DO_FW_ID:-${TCPUX_DO_FW_ID:-}}"

say(){ printf '\n=== %s ===\n' "$*"; }
on_err(){ echo "TCPUXDO_STEP_ERR (line $1)"; }
