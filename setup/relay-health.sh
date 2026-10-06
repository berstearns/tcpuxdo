#!/usr/bin/env bash
# Local queue RPC health probe (does not prove fleet health).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] || exit 1
set -o allexport; . ./.env; set +o allexport
python3 - "$TCPUX_HOST" "$TCPUX_PORT" <<'PY'
import sys
from proto import rpc
r = rpc(sys.argv[1], int(sys.argv[2]), {"op":"state"})
if not r.get("ok") or not isinstance(r.get("state"), dict): raise SystemExit(1)
print("relay=healthy")
PY
