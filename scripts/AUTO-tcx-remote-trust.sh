#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-trust.sh — answer Claude Code's first-run dialogs in
#          a REMOTE pane, from m1, until claude's input box is visible:
#            - "Do you trust this folder?"            → Yes, I trust this folder
#            - "Bypass Permissions mode" (when claude was started with
#              --dangerously-skip-permissions)         → Yes, I accept
#
# WHY:     2026-10-02: the first remote-app11-fence pair stopped on the trust
#          dialog ("No, exit" pre-selected) and only worked after a hand-typed
#          Down+Enter over tcpuxdo. A hand-typed fix-up means the step is
#          incomplete (single-seat-of-agency rule) — this is that step. Remote
#          pairs now run claude with --dangerously-skip-permissions (same as
#          tcx-claude, so the remote agent never blocks on tool prompts), which
#          adds the one-time bypass-mode dialog handled here too.
#
# INPUTS:  [WORKER PANE]   remote pane; default = the shared target file
#                          ${XDG_CACHE_HOME:-~/.cache}/tcpuxdo/target
#          TCX_TRUST_WAIT  seconds to wait for claude to draw (default 40)
#          -n              dry run: read the pane, print the decision, send nothing
#
# OUTPUTS: stdout = one line per decision:
#          "trust<TAB>worker<TAB>pane<TAB>state<TAB>detail"
#          state ∈ ready | accepted | dry-run | timeout | error
#          exit 0 ready/accepted · 1 timeout/error · 3 relay unreachable · 64 usage
#
# DECISION (never blind): the cursor position is READ from the dialog first.
#   "❯ No, exit" selected      → send ESC[B (Down); tcpuxdo appends the Enter
#   "❯ Yes, I trust/accept"    → send an empty line (Enter only)
#   claude input box shown     → nothing to do (ready)
# Up to 3 dialogs in a row are answered, each re-read before the next send.
#
# RE-RUN SAFETY: idempotent — a pane already past the dialogs reports "ready"
#          and sends nothing.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
TARGET_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/target"
WAIT="${TCX_TRUST_WAIT:-40}"
DRY=0

[[ "${1:-}" == "-n" ]] && { DRY=1; shift; }
case $# in
    0) [[ -s "$TARGET_FILE" ]] || { echo "trust: no args and no $TARGET_FILE" >&2; exit 64; }
       IFS=$'\t' read -r W P < "$TARGET_FILE" ;;
    2) W="$1"; P="$2" ;;
    *) echo "usage: AUTO-tcx-remote-trust.sh [-n] [WORKER PANE]" >&2; exit 64 ;;
esac
[[ -x "$TCPUXDO" ]] || { echo "trust: missing $TCPUXDO" >&2; exit 64; }

out(){ printf 'trust\t%s\t%s\t%s\t%s\n' "$W" "$P" "$1" "$2"; }
read_pane(){
    local diagnostic rc
    diagnostic="$(mktemp)" || return 1
    timeout 15 "$TCPUXDO" read -w "$W" -p "$P" --wait 12 2>"$diagnostic"
    rc=$?
    if (( rc != 0 )); then
        printf 'trust: remote pane capture failed (exit %s):\n' "$rc" >&2
        cat "$diagnostic" >&2
    fi
    rm -f "$diagnostic"
    return "$rc"
}

classify(){  # stdin = pane text → dialog-no | dialog-yes | ready | unknown
    local t; t="$(cat)"
    if grep -qE 'trust this folder|Bypass Permissions mode' <<<"$t"; then
        if   grep -qE '❯ *([0-9]\. *)?No, exit' <<<"$t"; then echo dialog-no
        elif grep -qE '❯ *([0-9]\. *)?Yes, I (trust|accept)' <<<"$t"; then echo dialog-yes
        else echo unknown; fi
    # claude's footer: "? for shortcuts" in manual mode, but in bypass mode it is
    # "⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents" — no "shortcuts".
    elif grep -qE 'for shortcuts|bypass permissions on|shift\+tab to cycle' <<<"$t"; then echo ready
    else echo unknown; fi
}

wait_state(){  # poll until a known state or the deadline
    local deadline=$(( SECONDS + WAIT )) s text failed=0
    while (( SECONDS < deadline )); do
        if ! text="$(read_pane)"; then
            failed=1
            sleep 3
            continue
        fi
        s="$(classify <<<"$text")"
        [[ "$s" != unknown ]] && { echo "$s"; return; }
        sleep 3
    done
    if (( failed )); then echo error; else echo timeout; fi
}

answered=0
for _ in 1 2 3; do
    state="$(wait_state)"
    case "$state" in
        ready)   if (( answered )); then out accepted "$answered dialog(s) answered, claude input box visible"
                 else out ready "claude input box visible, no dialog"; fi; exit 0 ;;
        error)   out error "capture failed (relay?)"; exit 3 ;;
        timeout) out timeout "no claude dialog or prompt after ${WAIT}s"; exit 1 ;;
    esac
    if (( DRY )); then out dry-run "would answer $state"; exit 0; fi
    if [[ "$state" == dialog-no ]]; then
        sent="$("$TCPUXDO" -w "$W" -p "$P" -c $'\e[B' 2>&1)" || {
            out error "dialog selection rejected: $sent"; exit 1;
        }
    else
        sent="$("$TCPUXDO" enter -w "$W" -p "$P" 2>&1)" || {
            out error "Enter rejected: $sent"; exit 1;
        }
    fi
    answered=$(( answered + 1 ))
    sleep 4
done
out error "still on a dialog after 3 answers"; exit 1
