#!/usr/bin/env bash
# End-to-end smoke test from main: confirm the relay answers, a node is
# registered, and a harmless send-keys lands. Pass the node name as $1 (or set
# TCPUX_WORKER). Optionally pass a pane id as $2 (default: first idle pane).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

WNAME="${1:-${TCPUX_WORKER:?give a node name: bash setup/04-verify.sh <node>}}"

say "1. Relay answers ($VPS_HOST:$PORT)"
PYTHONPATH="$REPO_ROOT" python3 - "$WNAME" "${2:-}" <<'PY'
import os, sys
from proto import rpc
host, port = os.environ["TCPUX_HOST"], int(os.environ["TCPUX_PORT"])
wname = sys.argv[1]; want_pane = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
r = rpc(host, port, {"op": "state"}); state = r.get("state", {})
print(f"   {len(state)} node(s) registered: {', '.join(sorted(state)) or '(none)'}")
if wname not in state:
    print(f"   FAIL node '{wname}' not registered — is its worker running?"); sys.exit(1)
panes = state[wname].get("panes", {})
idle = want_pane or next((p for p,v in sorted(panes.items()) if not v.get("busy")), None)
if not idle:
    print(f"   FAIL no idle pane on '{wname}' to test against"); sys.exit(1)
print(f"   target pane: {idle}")
# A harmless, visible no-op: print a marker into the pane.
marker = "tcpuxdo_verify_ok"
res = rpc(host, port, {"op":"send-keys","worker":wname,"pane":idle,"cmd":f"echo {marker}"})
print("   submit result:", res)
print("VERIFY_OK" if res.get("ok") or res.get("queued") else "VERIFY_SUBMITTED")
PY
echo "VERIFY_DONE — check the node's pane (or its obs pane) for 'tcpuxdo_verify_ok'."
