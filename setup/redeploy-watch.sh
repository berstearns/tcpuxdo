#!/usr/bin/env bash
# Apply one master-selected revision to this managed checkout. No secrets are logged.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"
TARGET_SHA="${REDEPLOY_SHA:-}"
[[ -z "${REDEPLOY_BRANCH:-}" ]] || { echo 'REDEPLOY_BRANCH is unsupported; supply a pinned REDEPLOY_SHA' >&2; exit 2; }
ROLE="${REDEPLOY_ROLE:-auto}"
TIMEOUT="${REDEPLOY_HEALTH_TIMEOUT:-45}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid REDEPLOY_HEALTH_TIMEOUT' >&2; exit 2; }
case "$ROLE" in worker|relay|client) ;; *) echo 'set REDEPLOY_ROLE to worker, relay, or client' >&2; exit 2 ;; esac
[[ "$TARGET_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'REDEPLOY_SHA must be a full 40-character commit SHA' >&2; exit 2; }
TARGET_SHA="$(printf '%s' "$TARGET_SHA" | tr 'A-F' 'a-f')"
GIT_DIR="$(git rev-parse --absolute-git-dir)"
STATE_DIR="$GIT_DIR/tcpuxdo-redeploy"
mkdir -p "$STATE_DIR"
LOCK="${REDEPLOY_LOCK:-$STATE_DIR/${ROLE}.lock}"
exec 9>"$LOCK"; flock -n 9 || { echo 'status=already-running'; exit 0; }
OLD_SHA="$(git rev-parse HEAD)"
RESULT="${REDEPLOY_RESULT:-$STATE_DIR/${ROLE}.result}"
clean_tree() {
  git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]
}
write_result() {
  local state="$1" observed="$2" health="$3" err="${4:-}"
  local tmp="${RESULT}.tmp.$$"
  umask 077
  printf 'status=%s\nold_sha=%s\nrequested_sha=%s\nobserved_sha=%s\nhealth=%s\nrole=%s\nupdated_at=%s\nerror=%s\n' \
    "$state" "$OLD_SHA" "$TARGET_SHA" "$observed" "$health" "$ROLE" "$(date -u +%FT%TZ)" "$err" > "$tmp"
  mv -f "$tmp" "$RESULT"
}
if [[ "$OLD_SHA" == "$TARGET_SHA" ]]; then
  clean_tree || { write_result dirty "$OLD_SHA" unknown dirty-tree; exit 1; }
  health="unchanged"
  if [[ "$ROLE" == worker ]]; then bash setup/worker-health.sh || health=unavailable
  elif [[ "$ROLE" == relay ]]; then bash setup/relay-health.sh || health=unavailable; fi
  [[ "$health" != unavailable ]] || { write_result failed "$OLD_SHA" unavailable health-failed; exit 1; }
  write_result healthy "$OLD_SHA" "$health"
  echo "status=healthy old_sha=$OLD_SHA requested_sha=$TARGET_SHA observed_sha=$OLD_SHA health=$health"
  exit 0
fi
clean_tree || { write_result dirty "$OLD_SHA" unknown dirty-tree; exit 1; }
git fetch --quiet origin "$TARGET_SHA" || { write_result failed "$OLD_SHA" unknown fetch-failed; exit 1; }
git cat-file -e "$TARGET_SHA^{commit}" || { write_result failed "$OLD_SHA" unknown missing-commit; exit 1; }
git diff --quiet "$OLD_SHA" "$TARGET_SHA" -- . ':(exclude).env' || { write_result failed "$OLD_SHA" unknown target-modifies-working-tree; echo 'target checkout would overwrite local modifications; refusing' >&2; exit 1; }
git merge-base --is-ancestor "$OLD_SHA" "$TARGET_SHA" || { write_result failed "$OLD_SHA" unknown non-fast-forward; echo 'refusing non-fast-forward revision' >&2; exit 1; }
git checkout --detach "$TARGET_SHA"
restart_component() {
  case "$ROLE" in
    worker) bash setup/worker-restart.sh ;;
    relay) bash setup/relay-restart.sh ;;
    client) : ;;
    *) return 2 ;;
  esac
}
health_check() {
  case "$ROLE" in
    worker) [[ -f .env ]] && bash setup/worker-health.sh ;;
    relay) [[ -f .env ]] && bash setup/relay-health.sh ;;
    client)
      if [[ -x "./$(basename "$ROOT")" ]]; then "./$(basename "$ROOT")" doctor >/dev/null 2>&1
      else git rev-parse --verify HEAD >/dev/null; fi ;;
  esac
}
if ! restart_component; then
  NEW_SHA="$(git rev-parse HEAD)"; git checkout --detach "$OLD_SHA"; restart_component || true
  write_result failed "$NEW_SHA" restart-failed
  exit 1
fi
deadline=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < deadline )); do
  if health_check; then
    OBSERVED="$(git rev-parse HEAD)"
    [[ "$OBSERVED" == "$TARGET_SHA" ]] || break
    write_result healthy "$OBSERVED" ok
    echo "status=healthy old_sha=$OLD_SHA requested_sha=$TARGET_SHA observed_sha=$OBSERVED health=ok"
    exit 0
  fi
  sleep 2
done
NEW_SHA="$(git rev-parse HEAD)"
git checkout --detach "$OLD_SHA"
rollback=failed
if restart_component; then
  deadline=$(( $(date +%s) + TIMEOUT ))
  while (( $(date +%s) < deadline )); do health_check && { rollback=healthy; break; }; sleep 2; done
fi
write_result failed "$NEW_SHA" health-timeout "rollback-$rollback"
echo "status=failed old_sha=$OLD_SHA requested_sha=$TARGET_SHA observed_sha=$NEW_SHA health=timeout rollback=$rollback" >&2
exit 1
