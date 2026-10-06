#!/usr/bin/env bash
# Local worker health probe. Requires a recent worker registration through relay.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] || exit 1
set -o allexport; . ./.env; set +o allexport
python3 - "$TCPUX_HOST" "$TCPUX_PORT" "${TCPUX_WORKER:-$(hostname)}" "$(git rev-parse --short=8 HEAD)" <<'PY'
import sys, time
from proto import rpc
r = rpc(sys.argv[1], int(sys.argv[2]), {"op":"state"})
w = r.get("state", {}).get(sys.argv[3])
if not w or time.time() - float(w.get("last_update", 0)) > 30:
    raise SystemExit(1)
meta = w.get("meta") or {}
expected = sys.argv[4]
observed = str(meta.get("sha", ""))
if len(expected) != 8 or observed != expected or not all(c in "0123456789abcdefABCDEF" for c in observed):
    raise SystemExit(1)
print("worker=healthy sha=" + observed + " (8-char worker metadata)")
PY
