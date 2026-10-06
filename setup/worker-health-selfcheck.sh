#!/usr/bin/env bash
# Verify health probe matches relay worker.py metadata's short SHA representation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/setup"
cp "$ROOT/setup/worker-health.sh" "$TMP/repo/setup/worker-health.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=selfcheck@example.invalid -c user.name=selfcheck commit --allow-empty -qm initial
FULL="$(git -C "$TMP/repo" rev-parse HEAD)"; SHORT="$(git -C "$TMP/repo" rev-parse --short=8 HEAD)"
cat > "$TMP/repo/.env" <<'EOF'
TCPUX_HOST=local-test
TCPUX_PORT=1
TCPUX_WORKER=selfcheck
EOF
cat > "$TMP/repo/proto.py" <<'PY'
import json, os
def rpc(*args): return json.loads(os.environ["FAKE_RELAY_STATE"])
PY
export FAKE_RELAY_STATE="$(/usr/bin/python3 -c 'import json,time,sys; print(json.dumps({"state":{"selfcheck":{"last_update":time.time(),"meta":{"sha":sys.argv[1]}}}}))' "$SHORT")"
(cd "$TMP/repo" && bash setup/worker-health.sh)
STALE="$(/usr/bin/python3 -c 'import sys; print(("0" if sys.argv[1][0] != "0" else "1") + sys.argv[1][1:])' "$SHORT")"
export FAKE_RELAY_STATE="$(/usr/bin/python3 -c 'import json,time,sys; print(json.dumps({"state":{"selfcheck":{"last_update":time.time(),"meta":{"sha":sys.argv[1]}}}}))' "$STALE")"
if (cd "$TMP/repo" && bash setup/worker-health.sh) >/dev/null 2>&1; then
  echo 'FAIL stale short SHA accepted' >&2; exit 1
fi
export FAKE_RELAY_STATE="$(/usr/bin/python3 -c 'import json,time; print(json.dumps({"state":{"selfcheck":{"last_update":time.time(),"meta":{"sha":"zzzzzzzz"}}}}))')"
if (cd "$TMP/repo" && bash setup/worker-health.sh) >/dev/null 2>&1; then
  echo 'FAIL non-hex SHA accepted' >&2; exit 1
fi
echo 'worker-health-selfcheck: PASS (8-char SHA accepted; stale and non-hex values rejected)'
