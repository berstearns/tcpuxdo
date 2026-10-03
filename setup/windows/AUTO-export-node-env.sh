#!/usr/bin/env bash
# WHAT:    Export a NODE-scoped tcpuxdo env (node.env) from m1's authoritative
#          relay coordinates, for inclusion in the reconnect bundle. The button
#          applies this to the m2 node so a stale/broken/missing m2 .env is
#          corrected FROM m1, not trusted.
# WHY:     The reconnect worker only fixes a dead PROCESS if it can already dial
#          the relay. If the outage is a wrong TCPUX_HOST/PORT on m2, restarting
#          the worker just re-dials the wrong place. Shipping the current coords
#          from m1 makes the button fix the config too.
# INPUTS:  --name NAME   the NODE's registry name written as TCPUX_WORKER
#                        (default: wsl-) — this is the node's identity, NOT m1's
#          --from FILE   source env to read HOST/PORT/POLL/SYNC from
#                        (default: $TCPUXDO_DIR/.env or ~/p/tcpuxdo/.env)
#          -o FILE       output (default: <script dir>/node.env)
# OUTPUTS: node.env with TCPUX_HOST, TCPUX_PORT, TCPUX_WORKER (+POLL/SYNC if set).
#          DELIBERATELY omits TCPUX_ADMIN_TOKEN — the worker never needs it, and
#          its absence keeps the bundle safe on a public download link.
#          exit 0 written · 64 usage · 1 source unreadable / no HOST/PORT
# USAGE (combinatorial):
#   bash setup/windows/AUTO-export-node-env.sh                     # name=wsl-, from m1 .env
#   bash setup/windows/AUTO-export-node-env.sh --name wsl-         # explicit node name
#   bash setup/windows/AUTO-export-node-env.sh --from /srv/tcpuxdo/.env -o /tmp/node.env
# RE-RUN SAFETY: idempotent — overwrites the output each run; read-only on source.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
NAME="wsl-"; FROM="${TCPUXDO_DIR:-$HOME/p/tcpuxdo}/.env"; OUT="$HERE/node.env"
while [ "$#" -gt 0 ]; do case "$1" in
  --name) NAME="$2"; shift 2 ;;
  --from) FROM="$2"; shift 2 ;;
  -o)     OUT="$2";  shift 2 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 64 ;;
esac; done
[ -r "$FROM" ] || { echo "cannot read source env: $FROM" >&2; exit 1; }

# `|| true`: an OPTIONAL key (TCPUX_POLL/SYNC) that is absent makes grep exit 1,
# which under `set -euo pipefail` silently killed the whole export (2026-10-03).
get() { { grep -E "^$1=" "$FROM" || true; } | head -1 | cut -d= -f2- | sed 's/^["'\'']//; s/["'\'']$//'; }
HOST="$(get TCPUX_HOST)"; PORT="$(get TCPUX_PORT)"
POLL="$(get TCPUX_POLL)"; SYNC="$(get TCPUX_SYNC)"
[ -n "$HOST" ] && [ -n "$PORT" ] || { echo "source env lacks TCPUX_HOST/TCPUX_PORT" >&2; exit 1; }

{
  echo "# node.env — relay coordinates exported from m1 $(: authoritative)"
  echo "# Applied to the node by AUTO-worker-bringup.sh. NO admin token by design."
  echo "TCPUX_HOST=$HOST"
  echo "TCPUX_PORT=$PORT"
  echo "TCPUX_WORKER=$NAME"
  [ -n "$POLL" ] && echo "TCPUX_POLL=$POLL"
  [ -n "$SYNC" ] && echo "TCPUX_SYNC=$SYNC"
} > "$OUT"
chmod 600 "$OUT"
printf '%s\n' "$OUT"
