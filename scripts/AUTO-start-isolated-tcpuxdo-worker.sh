#!/usr/bin/env bash
# WHAT:    Clone and start one isolated tcpuxdo worker canary through relay-addressed tmux operations.
# WHY:     The live workers may have dirty checkouts or active jobs; this records a repeatable laptop-only path that clones the published feature SHA into a new folder/session and leaves existing workers alone.
# INPUTS:  start TARGET_WORKER TARGET_CONTROL_PANE SOURCE_ROOT NEW_ROOT SESSION NEW_WORKER BRANCH
#          stop  TARGET_WORKER TARGET_CONTROL_PANE SESSION
#          TCPUXDO_BIN (required): configured local tcpuxdo executable; it supplies relay settings from the main checkout.
#          TCPUXDO_WAIT (default 180): seconds allowed for the new worker to report fresh state.
# OUTPUTS: writes no local files. Mutates remote Git/tmux state only in the new folder/session. Exit 0=healthy/stopped, 1=remote failure/timeout, 64=usage/configuration error.
# USAGE (combinatorial):
#   TCPUXDO_BIN=/path/to/main/tcpuxdo ./scripts/AUTO-start-isolated-tcpuxdo-worker.sh start do-app11 tcpuxdo-worker:0:2 '~/p/tcpuxdo' '~/p/tcpuxdo-recovery' tcpuxdo-recovery-do-app11 do-app11-recovery feat/tmux-agent-replacement-next
#       # fresh feature-branch worker alongside the existing do-app11 worker
#   TCPUXDO_BIN=/path/to/main/tcpuxdo ./scripts/AUTO-start-isolated-tcpuxdo-worker.sh start wsl- tcpuxdo-worker:1:3 '~/tcpuxdo' '~/tcpuxdo-recovery' tcpuxdo-recovery-wsl wsl-recovery feat/tmux-agent-replacement-next
#       # fresh feature-branch worker alongside the existing WSL worker
#   TCPUXDO_BIN=/path/to/main/tcpuxdo ./scripts/AUTO-start-isolated-tcpuxdo-worker.sh stop wsl- tcpuxdo-worker:1:3 tcpuxdo-recovery-wsl
#       # stop only the named isolated canary session through its existing control shell
#   TCPUXDO_BIN=/path/to/main/tcpuxdo ./scripts/AUTO-start-isolated-tcpuxdo-worker.sh start wsl- tcpuxdo-worker:1:3 '~/tcpuxdo' '~/tcpuxdo-recovery' tcpuxdo-recovery-wsl wsl-recovery master
#       # same operation against another published branch
#   ./scripts/AUTO-start-isolated-tcpuxdo-worker.sh
#       # invalid: prints usage and exits 64 because mode/arguments are required
# RE-RUN SAFETY: start refuses an existing worker ID, session, or destination folder; stop targets only the explicitly named tcpuxdo-recovery-* session. Re-run start after inspecting/removing a failed canary; it never touches the source worker session.
set -euo pipefail

usage() { sed -n '1,24p' "$0"; }
fail_usage() { usage >&2; exit 64; }
remote_path() {
  case "$1" in
    '~/'*) printf "~/'%s'" "${1#\~/}" ;;
    /*) printf '%q' "$1" ;;
  esac
}

MODE="${1:-}"; shift || true
TCPUXDO_BIN="${TCPUXDO_BIN:-}"
WAIT="${TCPUXDO_WAIT:-180}"
[[ -n "$TCPUXDO_BIN" && -x "$TCPUXDO_BIN" ]] || { echo 'TCPUXDO_BIN must name the configured main tcpuxdo executable' >&2; exit 64; }
[[ "$WAIT" =~ ^[1-9][0-9]*$ ]] || { echo 'TCPUXDO_WAIT must be a positive integer' >&2; exit 64; }

case "$MODE" in
  start)
    [[ $# -eq 7 ]] || fail_usage
    TARGET="$1"; CONTROL="$2"; SOURCE_ROOT="$3"; NEW_ROOT="$4"; SESSION="$5"; NEW_WORKER="$6"; BRANCH="$7"
    [[ "$TARGET" =~ ^[A-Za-z0-9._-]+$ && "$NEW_WORKER" =~ ^[A-Za-z0-9._-]+$ ]] || fail_usage
    [[ "$CONTROL" =~ ^[A-Za-z0-9_-]+:[0-9]+:[0-9]+$ ]] || fail_usage
    [[ "$SESSION" =~ ^tcpuxdo-recovery-[A-Za-z0-9_-]+$ ]] || { echo 'SESSION must begin tcpuxdo-recovery-' >&2; exit 64; }
    [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || fail_usage
    for p in "$SOURCE_ROOT" "$NEW_ROOT"; do [[ "$p" =~ ^(~/[A-Za-z0-9._/-]+|/[A-Za-z0-9._/-]+)$ ]] || fail_usage; done
    [[ "$SOURCE_ROOT" != "$NEW_ROOT" ]] || { echo 'SOURCE_ROOT and NEW_ROOT must differ' >&2; exit 64; }
    jq -e . >/dev/null 2>&1 <<<"$($TCPUXDO_BIN --op state)" || { echo 'relay state unavailable' >&2; exit 1; }
    STATE="$($TCPUXDO_BIN --op state)"
    jq -e --arg w "$TARGET" '.state[$w] != null' >/dev/null <<<"$STATE" || { echo "target worker $TARGET is not registered" >&2; exit 1; }
    jq -e --arg w "$NEW_WORKER" '.state[$w] == null' >/dev/null <<<"$STATE" || { echo "new worker ID $NEW_WORKER is already registered" >&2; exit 1; }
    SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    SHA="$(git -C "$SCRIPT_ROOT" rev-parse HEAD)"
    SHORT="${SHA:0:8}"
    echo "target=$TARGET new_worker=$NEW_WORKER session=$SESSION branch=$BRANCH sha=$SHA"
    "$TCPUXDO_BIN" --op create-session --worker "$TARGET" --session "$SESSION"
    deadline=$(( $(date +%s) + WAIT ))
    BOOT_PANE=""
    while (( $(date +%s) < deadline )); do
      STATE="$($TCPUXDO_BIN --op state)"
      BOOT_PANE="$(jq -r --arg w "$TARGET" --arg s "$SESSION" '[.state[$w].panes // {} | keys[] | select(startswith($s+":"))] | first // ""' <<<"$STATE")"
      [[ -n "$BOOT_PANE" ]] && break
      sleep 2
    done
    [[ -n "$BOOT_PANE" ]] || { echo 'new tmux bootstrap pane did not register before deadline' >&2; exit 1; }
    qsrc="$(remote_path "$SOURCE_ROOT")"; qnew="$(remote_path "$NEW_ROOT")"
    CMD="tmux select-pane -t \"\$TMUX_PANE\" -T 'tcpuxdo-recovery-bootstrap-${TARGET}' && git clone --branch '$BRANCH' --single-branch 'https://github.com/berstearns/tcpuxdo.git' $qnew && cd $qnew && git pull --ff-only origin '$BRANCH' && test \"\$(git rev-parse HEAD)\" = '$SHA' && grep -E '^(TCPUX_HOST|TCPUX_PORT|PYTHON|TCPUX_POLL|TCPUX_SYNC|TCPUX_IDLE_CMDS)=' $qsrc/.env > .env && printf '%s\\n' 'TCPUX_WORKER=$NEW_WORKER' 'WORKER_SESSION=$SESSION' 'WORKER_WINDOW=worker' 'WORKER_PANE_MAIN=tcpuxdo-recovery-main-${TARGET}' 'WORKER_PANE_OBS=tcpuxdo-recovery-observer-${TARGET}' 'WORKER_PANE_CTL=tcpuxdo-recovery-control-${TARGET}' 'WORKER_PANE_WATCH=tcpuxdo-recovery-watch-${TARGET}' >> .env && bash setup/node-up.sh"
    "$TCPUXDO_BIN" -w "$TARGET" -p "$BOOT_PANE" -c "$CMD"
    echo 'dispatch=queued; waiting for a fresh relay heartbeat from the isolated worker'
    deadline=$(( $(date +%s) + WAIT ))
    while (( $(date +%s) < deadline )); do
      STATE="$($TCPUXDO_BIN --op state)"
      reported="$(jq -r --arg w "$NEW_WORKER" '.state[$w].meta.sha // ""' <<<"$STATE")"
      branch_seen="$(jq -r --arg w "$NEW_WORKER" '.state[$w].meta.branch // ""' <<<"$STATE")"
      dirty="$(jq -r --arg w "$NEW_WORKER" '.state[$w].meta.dirty // true' <<<"$STATE")"
      stamp="$(jq -r --arg w "$NEW_WORKER" '.state[$w].last_update // 0 | floor' <<<"$STATE")"
      now="$(date +%s)"
      if [[ "$reported" == "$SHORT" && "$branch_seen" == "$BRANCH" && "$dirty" == false ]] && (( now - stamp <= 30 )); then
        echo "status=healthy worker=$NEW_WORKER session=$SESSION branch=$branch_seen sha=$reported dirty=$dirty heartbeat_age=$((now-stamp))s"
        exit 0
      fi
      sleep 3
    done
    echo "status=timeout target=$TARGET new_worker=$NEW_WORKER session=$SESSION; inspect the bootstrap pane; source worker was not changed" >&2
    exit 1
    ;;
  stop)
    [[ $# -eq 3 ]] || fail_usage
    TARGET="$1"; CONTROL="$2"; SESSION="$3"
    [[ "$TARGET" =~ ^[A-Za-z0-9._-]+$ && "$CONTROL" =~ ^[A-Za-z0-9_-]+:[0-9]+:[0-9]+$ && "$SESSION" =~ ^tcpuxdo-recovery-[A-Za-z0-9_-]+$ ]] || fail_usage
    STATE="$($TCPUXDO_BIN --op state)"
    jq -e --arg w "$TARGET" --arg s "$SESSION" '[.state[$w].panes // {} | keys[] | select(startswith($s+":"))] | length > 0' >/dev/null <<<"$STATE" || { echo "isolated session $SESSION not found on $TARGET" >&2; exit 1; }
    "$TCPUXDO_BIN" -w "$TARGET" -p "$CONTROL" -c "tmux kill-session -t '$SESSION'"
    echo "status=stop-queued target=$TARGET session=$SESSION; verify session panes disappear from relay state"
    ;;
  *) fail_usage ;;
esac
