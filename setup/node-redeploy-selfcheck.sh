#!/usr/bin/env bash
# Offline command-construction check for adoption and pinned relay dispatch.
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/setup"; cp "$SOURCE/node-redeploy.sh" "$TMP/setup/"
cat > "$TMP/tcpuxdo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE"
SH
chmod +x "$TMP/tcpuxdo"
cd "$TMP"
export CAPTURE="$TMP/args"
bash setup/node-redeploy.sh --adopt-default main worker tcpuxdo:worker:2 '~/tcpuxdo'
grep -Fq "REDEPLOY_BRANCH='main' bash ~/'tcpuxdo'/setup/redeploy-watch.sh" "$CAPTURE"
if grep -Eq '&&|git pull|worker-restart' "$CAPTURE"; then
  echo 'FAIL adoption dispatched an inline command sequence' >&2; exit 1
fi
bash setup/node-redeploy.sh worker tcpuxdo:worker:2 '~/tcpuxdo' 0123456789abcdef0123456789abcdef01234567
grep -Fq "cd ~/'tcpuxdo' && REDEPLOY_ROLE=worker REDEPLOY_SHA='0123456789abcdef0123456789abcdef01234567'" "$CAPTURE"
if bash setup/node-redeploy.sh worker tcpuxdo:worker:2 '~/path with spaces' 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo 'FAIL unsafe relative root accepted' >&2; exit 1
fi
echo 'node-redeploy-selfcheck: PASS (home-relative expansion, adoption guards, pinned command)'
