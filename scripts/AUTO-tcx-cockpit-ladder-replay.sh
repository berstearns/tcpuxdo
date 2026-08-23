#!/usr/bin/env bash
#===============================================================================
# WHAT:    Replays every commit of the cockpit branch in an isolated git
#          worktree and runs, at each one, the acceptance check that commit's
#          own message claims is green. Prints GREEN/BROKEN per commit.
#
# WHY:     `auto-rules/combinatorial-commits/every-commit-must-build-and-pass-
#          its-tests-on-its-own.md` requires each commit to stand alone: a SHA
#          that only works because the NEXT commit exists is a landmine for
#          bisect and revert. That property is a claim about history, and a
#          claim needs an artifact. `bash -n` is not the artifact — it proves
#          the file parses, not that the rung does what its message says.
#
#          It runs in a WORKTREE, never by checking out commits in place: a
#          checkout loop in the working repo will happily strand you on a
#          detached HEAD if any step fails, and it churns the files another
#          program may be running.
#
# INPUTS:  $1  base ref (default: the branch point, 694b240)
#          $2  tip ref  (default: HEAD)
#          Env: TCX_LADDER_WT  worktree path
#               (default: a temp dir under the system temp)
#
# OUTPUTS / SIDE EFFECTS:
#          stdout: one GREEN/BROKEN line per commit + a tally.
#          creates and removes a git worktree; the real working tree is never
#          checked out, moved, or left detached.
#          Creates and destroys throwaway tmux sessions named ladderreplay-*.
#          Sends nothing to any remote pane; every remote path is a dry run.
#          exit 0 every rung green · 1 at least one BROKEN · 2 setup failure.
#
# USAGE (combinatorial):
#   ./scripts/AUTO-tcx-cockpit-ladder-replay.sh
#       # the whole branch
#   ./scripts/AUTO-tcx-cockpit-ladder-replay.sh 694b240 135d2b7
#       # only up to the remote-half rung
#
# RE-RUN SAFETY: idempotent. Removes its worktree and tmux sessions on the way
#          in and on the way out.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BASE="${1:-694b240}"
TIP="${2:-HEAD}"
WT="${TCX_LADDER_WT:-${TMPDIR:-/tmp}/tcx-ladder-replay}"
SESS="ladderreplay"

G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; X=$'\033[0m'
GREEN=0; BROKEN=0

cleanup() {
    tmux kill-session -t "=$SESS-cockpit" 2>/dev/null
    git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null
    return 0
}
trap cleanup EXIT

cleanup
git -C "$ROOT" worktree add -q --detach "$WT" "$TIP" \
    || { echo "could not create a worktree at $WT" >&2; exit 2; }
# The engine wrapper refuses to run without .env, and .env is git-ignored, so
# the worktree needs its own copy. Without it every rung would fail for a
# reason that has nothing to do with the rung.
cp "$ROOT/.env" "$WT/.env" 2>/dev/null \
    || { echo "no $ROOT/.env to copy into the worktree" >&2; exit 2; }

cp_() { cp "$ROOT/.env" "$WT/.env" 2>/dev/null; return 0; }

# The cockpit dispatches to stage-1 engines that are NOT COMMITTED in this repo
# — `setup/tcx-stream.sh` and the `tcx-cli` surface exist only in the working
# tree. A pristine checkout of this branch therefore cannot run the cockpit, and
# a replay that quietly copied them in would hide that.
#
# So: copy them, and SAY SO, every run. A silent scope reduction is a failure;
# a logged one is a finding. This is the branch's real dependency gap, and it is
# not this branch's to close — the files belong to whoever left them untracked.
DEPS=(setup/tcx-stream.sh tcx-cli scripts/AUTO-tcx-cli.sh)
stage_untracked_deps() {
    local f first=1
    for f in "${DEPS[@]}"; do
        git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
        [[ -e "$ROOT/$f" ]] || continue
        if (( first )); then
            printf '%s  note:%s these dependencies are UNTRACKED in git and are being copied\n' "$D" "$X"
            printf '%s        into the worktree. A clean clone of this branch could not run:%s\n' "$D" "$X"
            first=0
        fi
        printf '%s          %s%s\n' "$D" "$f" "$X"
        mkdir -p "$WT/$(dirname "$f")"
        cp -a "$ROOT/$f" "$WT/$f" 2>/dev/null
    done
    return 0
}

# The check each rung must pass, keyed by the capability that rung introduces.
# Every one is a BEHAVIOUR, not a parse: a rung is green when it does what its
# commit message says it does.
check_rung() {  # $1 short sha  $2 subject -> rc 0 green
    local cock="$WT/scripts/AUTO-tcx-cockpit.sh" rc out

    # rung 1+ : the option surface
    bash "$cock" --help >/dev/null 2>&1        || return 1
    bash "$cock" --nonsense >/dev/null 2>&1; [[ $? == 64 ]] || return 1

    # rung 2+ : worker validation against live state
    if grep -q 'E_UNKNOWN_WORKER' "$cock"; then
        bash "$cock" -w no-such-worker-xyz -s "$SESS" -d '~' >/dev/null 2>&1
        [[ $? == 2 ]] || return 1
    fi

    # rung 3+ : profiles
    if grep -q 'E_NO_PROFILES' "$cock"; then
        env TCX_COCKPIT_PROFILES_FILE=/nonexistent/profiles.conf \
            bash "$cock" -p nosuch -w x -s "$SESS" -d '~' >/dev/null 2>&1
        [[ $? == 2 ]] || return 1
    fi

    # rung 4+ : the local cockpit really gets built, titled, and torn down
    if grep -q 'STREAM_TITLE' "$cock"; then
        tmux kill-session -t "=$SESS-cockpit" 2>/dev/null
        local args=(-s "$SESS")
        grep -q -- '--no-remote' "$cock" && args=(--no-remote -s "$SESS")
        env NO_COLOR=1 bash "$cock" "${args[@]}" >/dev/null 2>&1 || return 1
        out="$(tmux list-panes -s -t "=$SESS-cockpit" -F '#{pane_title}' 2>/dev/null \
               | sort | tr '\n' ',')"
        [[ "$out" == "tcx-send,tcx-stream," ]] || return 1
        env NO_COLOR=1 bash "$cock" --teardown -s "$SESS" >/dev/null 2>&1 || return 1
        tmux has-session -t "=$SESS-cockpit" 2>/dev/null && return 1
    fi

    # rung 5+ : the full dry run previews the remote ops and creates nothing
    if grep -q 'remote_half' "$cock"; then
        out="$(env TCX_COCKPIT_DEAD_SECS=99999999 NO_COLOR=1 \
               bash "$cock" -n -w "$(live_worker)" -s "$SESS" -d '~' 2>&1)"; rc=$?
        [[ $rc == 0 ]] || return 1
        grep -qF -- '--op create-session' <<<"$out" || return 1
        tmux has-session -t "=$SESS-cockpit" 2>/dev/null && return 1
    fi

    # the self-check, once it exists, is the rung's own gate
    if [[ -r "$WT/scripts/AUTO-tcx-cockpit-selfcheck.sh" ]]; then
        env TCX_COCKPIT_SELFCHECK_SESSION="$SESS-sc" \
            bash "$WT/scripts/AUTO-tcx-cockpit-selfcheck.sh" >/dev/null 2>&1 || return 1
    fi
    return 0
}

live_worker() {
    "$ROOT/tcpuxdo" --op state 2>/dev/null | jq -r '.state | keys[0] // "none"' 2>/dev/null
}

printf '%s== ladder replay: %s..%s ==%s\n' "$B" "$BASE" "$TIP" "$X"
stage_untracked_deps
while read -r sha; do
    subj="$(git -C "$ROOT" log -1 --format=%s "$sha")"
    git -C "$WT" checkout -q --detach "$sha" 2>/dev/null || { echo "checkout failed: $sha"; exit 2; }
    cp_
    stage_untracked_deps >/dev/null
    if check_rung "$sha" "$subj"; then
        GREEN=$((GREEN+1)); printf '  %sGREEN %s%s %s\n' "$G" "$(git -C "$ROOT" rev-parse --short "$sha")" "$X" "$subj"
    else
        BROKEN=$((BROKEN+1)); printf '  %sBROKEN%s %s %s\n' "$R" "$X" "$(git -C "$ROOT" rev-parse --short "$sha")" "$subj"
    fi
done < <(git -C "$ROOT" rev-list --reverse "$BASE..$TIP")

printf '\n%s%d GREEN%s  %s%d BROKEN%s\n' \
    "$G" "$GREEN" "$X" "$([[ $BROKEN -gt 0 ]] && echo "$R" || echo "$D")" "$BROKEN" "$X"
exit $(( BROKEN > 0 ))
