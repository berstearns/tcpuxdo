#!/usr/bin/env bash
# redeploy-watch.sh — pull-model auto-redeploy. CODE ONLY; never touches .env/creds.
#
# Invariant: under "code changed, .env + creds still valid", redeploy = git ff-pull +
# restart. .env (and *.key/*.enc/*.token/DBs) are git-ignored, so `git pull --ff-only`
# provably cannot modify identity or credentials. No keygen, no onboard.
#
# Steady state: a systemd timer (setup/redeploy.timer) runs this every few minutes.
# Instant override: from main, send `bash setup/redeploy-watch.sh` into a node's IDLE
# control pane (NOT the worker pane — that's busy and the idle-gate would reject it).
#
# Knobs (env; the systemd unit sets them, sane auto-defaults otherwise):
#   REDEPLOY_BRANCH   branch to track            (default: master)
#   REDEPLOY_RESTART  command to restart service (default: bash setup/node-up.sh if present)
#   REDEPLOY_HEALTH   must succeed post-restart   (default: ./<repo-cli> doctor, else true)
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
BRANCH="${REDEPLOY_BRANCH:-master}"

# auto-default the restart + health to the repo's own idempotent tooling
if [ -z "${REDEPLOY_RESTART:-}" ]; then
  [ -f setup/node-up.sh ] && REDEPLOY_RESTART="bash setup/node-up.sh" || REDEPLOY_RESTART=":"
fi
cli="$(basename "$ROOT")"   # repo dir name == CLI name for credpipe & tcpuxdo
if [ -z "${REDEPLOY_HEALTH:-}" ]; then
  [ -x "./$cli" ] && REDEPLOY_HEALTH="./$cli doctor >/dev/null 2>&1" || REDEPLOY_HEALTH="true"
fi

LOCK="/tmp/${cli}-redeploy.lock"
exec 9>"$LOCK"; flock -n 9 || { echo "redeploy busy ($cli)"; exit 0; }

log(){ echo "[$(date -u +%FT%TZ)] $*"; }

git fetch --quiet origin "$BRANCH" || { log "fetch failed"; exit 1; }
OLD="$(git rev-parse HEAD)"
NEW="$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "$OLD")"
[ "$OLD" = "$NEW" ] && exit 0          # nothing new — quiet no-op

log "redeploy $cli: ${OLD:0:8} → ${NEW:0:8} (branch $BRANCH)"
if ! git pull --ff-only origin "$BRANCH"; then
  log "DIVERGED — refusing non-ff merge; manual intervention required"; exit 1
fi
# .env / creds untouched here by construction (git-ignored).

eval "$REDEPLOY_RESTART"

if ! timeout 30 bash -c "$REDEPLOY_HEALTH"; then
  log "HEALTH FAIL after ${NEW:0:8} — rolling back to ${OLD:0:8}"
  git reset --hard "$OLD" >/dev/null
  eval "$REDEPLOY_RESTART"
  echo "$NEW $(date -u +%FT%TZ) ROLLED_BACK" >> .redeploy-ledger
  exit 1
fi
log "redeploy ok → ${NEW:0:8}"
echo "$NEW $(date -u +%FT%TZ) ok" >> .redeploy-ledger
