#!/usr/bin/env bash
# Offline validation for pinned updater guards and idempotent reporting.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"; cd "$TMP/repo"
git config user.email selfcheck@example.invalid; git config user.name selfcheck
mkdir -p setup; cp "$ROOT/setup/redeploy-watch.sh" setup/
echo one > data; git add .; git commit -qm one
OLD="$(git rev-parse HEAD)"
if REDEPLOY_SHA=bad REDEPLOY_ROLE=client bash setup/redeploy-watch.sh >"$TMP/out" 2>&1; then
  echo 'FAIL malformed SHA accepted' >&2; exit 1
fi
[[ "$(git rev-parse HEAD)" == "$OLD" ]]
if REDEPLOY_ROLE=client bash setup/redeploy-watch.sh >"$TMP/out" 2>&1; then
  echo 'FAIL missing desired version accepted' >&2; exit 1
fi
[[ "$(git rev-parse HEAD)" == "$OLD" ]]
if REDEPLOY_SHA=master REDEPLOY_BRANCH=master REDEPLOY_ROLE=client bash setup/redeploy-watch.sh >"$TMP/out" 2>&1; then
  echo 'FAIL branch name accepted instead of pinned SHA' >&2; exit 1
fi
if REDEPLOY_SHA="$OLD" REDEPLOY_BRANCH=master REDEPLOY_ROLE=client bash setup/redeploy-watch.sh >"$TMP/out" 2>&1; then
  echo 'FAIL legacy branch mode accepted' >&2; exit 1
fi
[[ "$(git rev-parse HEAD)" == "$OLD" ]]
echo scratch > untracked.tmp
if REDEPLOY_SHA="$OLD" REDEPLOY_ROLE=client REDEPLOY_RESULT="$TMP/result" bash setup/redeploy-watch.sh >"$TMP/out" 2>&1; then
  echo 'FAIL untracked file accepted' >&2; exit 1
fi
rm untracked.tmp
[[ "$(git rev-parse HEAD)" == "$OLD" ]]
echo two >> data; git add data; git commit -qm two; NEW="$(git rev-parse HEAD)"
git clone -q --bare . "$TMP/origin.git"
git remote add origin "$TMP/origin.git"
# A later pinned revision is accepted only when all its tracked files can be applied cleanly.
REDEPLOY_SHA="$NEW" REDEPLOY_ROLE=client REDEPLOY_RESULT="$TMP/result" bash setup/redeploy-watch.sh
grep -qx 'status=healthy' <(sed -n '1p' "$TMP/result")
[[ "$(git rev-parse HEAD)" == "$NEW" ]]
REDEPLOY_SHA="$NEW" REDEPLOY_ROLE=client REDEPLOY_RESULT="$TMP/result" bash setup/redeploy-watch.sh
[[ "$(git rev-parse HEAD)" == "$NEW" ]]
REDEPLOY_SHA="$NEW" REDEPLOY_ROLE=client bash setup/redeploy-watch.sh
[[ -f .git/tcpuxdo-redeploy/client.result ]]
[[ -z "$(git status --porcelain)" ]]
echo 'redeploy-selfcheck: PASS (pinned update, repeat, untracked/branch/malformed contract guards, git-metadata artifacts)'
