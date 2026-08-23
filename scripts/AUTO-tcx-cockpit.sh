#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-cockpit.sh — the stage-2 cockpit CLI so far: the option
#          surface, the dry-run preview machinery, and a preflight that reads
#          LIVE relay state to validate the worker. It resolves and CHECKS its
#          inputs, then prints the plan. It builds nothing yet.
#
# WHY:     The two halves this will grow (a remote Claude pane, a local two-pane
#          cockpit) both hang off one argument surface and one preview
#          mechanism, and both are dangerous to get wrong: one types into a live
#          terminal, the other rewrites a shared target file. Landing the
#          skeleton first means the flag parsing, the exit-code contract, and
#          the "print it, do not run it" path are provable before anything can
#          act on them.
#
# INPUTS:  -w, --worker NAME    target worker
#          -s, --session NAME   remote session name; local becomes <name>-cockpit
#          -d, --dir PATH       remote working directory for claude
#          -n, --dry-run        print every command, run NOTHING
#              --no-color       disable ANSI
#          -h, --help
#
#          Env overrides: TCX_COCKPIT_WORKER, TCX_COCKPIT_SESSION,
#          TCX_COCKPIT_DIR, TCX_COCKPIT_DEAD_SECS, TCX_COCKPIT_HOST,
#          TCX_COCKPIT_PORT.
#
# OUTPUTS / SIDE EFFECTS:
#          stdout, plus ONE read-only relay RPC (--op state). Nothing is
#          created, nothing is sent, no file is written.
#          exit 0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable
#          · 64 usage error.
#
# USAGE (combinatorial):
#   AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
#       # resolve the three inputs and print the plan
#   AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
#       # the same, in dry-run mode
#   AUTO-tcx-cockpit.sh -w no-such-worker -s ferret -d '~'
#       # INVALID: unknown worker, exit 2, with the live worker list
#   AUTO-tcx-cockpit.sh --nonsense
#       # INVALID: unknown option, exit 64
#
# NOT IN THIS COMMIT, on purpose: the rofi prompts, the remote session, and the
#          local cockpit. Each lands as its own rung so it can be reverted
#          without taking the option surface or the validation with it.
#
# RE-RUN SAFETY: read-only and idempotent — there is nothing here to mutate yet.
#===============================================================================

set -uo pipefail   # NOT -e: exit codes are handled explicitly, everywhere.

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TCPUXDO="$REPO/tcpuxdo"

# ============================================================================
# CONFIG: env-var overridable, so one i3 binding can be re-purposed
#   bindsym $mod+Ctrl+Shift+c exec --no-startup-id \
#       TCX_COCKPIT_WORKER=newlaptop /home/b/p/tcpuxdo/scripts/AUTO-tcx-cockpit.sh
# ============================================================================
declare -A CONFIG=(
    [worker]="${TCX_COCKPIT_WORKER:-}"
    [session]="${TCX_COCKPIT_SESSION:-}"
    [dir]="${TCX_COCKPIT_DIR:-}"
    # A worker silent longer than this is treated as DEAD: submitting to it
    # queues an op nobody will ever run, which looks exactly like success.
    [dead_secs]="${TCX_COCKPIT_DEAD_SECS:-180}"
    # Relay override, forwarded to client.py as --host/--port.
    #
    # This exists because ./tcpuxdo does `set -o allexport; . .env`, which makes
    # .env OVERRIDE the caller's environment. So `TCPUX_PORT=1 cockpit …` does
    # NOT point at a dead port — it quietly talks to the production relay, and
    # an "unreachable relay" test written that way passes while testing nothing
    # (the same trap AUTO-tcx-cli.sh documents in its .env loader). An explicit
    # --host/--port on client.py's argv beats the sourced default, so that is
    # the only reliable way to aim this somewhere else.
    [host]="${TCX_COCKPIT_HOST:-}"
    [port]="${TCX_COCKPIT_PORT:-}"
)

# Relay-override flags, kept as an ARRAY and spliced into every tcpuxdo argv.
# Never built with `$(cond && echo -n …)`: that substitution can expand to
# nothing and silently drop the flag (ergonomic rule 01).
RELAY_FLAGS=()
build_relay_flags() {
    RELAY_FLAGS=()
    [[ -n "${CONFIG[host]}" ]] && RELAY_FLAGS+=(--host "${CONFIG[host]}")
    [[ -n "${CONFIG[port]}" ]] && RELAY_FLAGS+=(--port "${CONFIG[port]}")
    return 0
}

DRY=0

# ── output ──────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'
else
    B=""; D=""; X=""; G=""; Y=""; R=""; C=""
fi

# Every failure exits through here, so every failure has a NAME. A silent
# fallthrough is the one outcome this script must never produce.
die() {  # $1 ERROR_NAME  $2 message  $3 exit code (default 1)
    printf '%scockpit: %s%s %s\n' "$R" "$1" "$X" "$2" >&2
    exit "${3:-1}"
}
note() { printf '%scockpit:%s %s\n' "$D" "$X" "$*" >&2; }
step() { printf '%s▸%s %s\n' "$C" "$X" "$*" >&2; }

# ============================================================================
# CLI Argument Parser
# ============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)     show_help; exit 0 ;;
            -w|--worker)   [[ $# -ge 2 ]] || die E_USAGE "-w needs a value" 64
                           CONFIG[worker]="$2"; shift 2 ;;
            -s|--session)  [[ $# -ge 2 ]] || die E_USAGE "-s needs a value" 64
                           CONFIG[session]="$2"; shift 2 ;;
            -d|--dir)      [[ $# -ge 2 ]] || die E_USAGE "-d needs a value" 64
                           CONFIG[dir]="$2"; shift 2 ;;
            -n|--dry-run)  DRY=1; shift ;;
            --no-color)    B=""; D=""; X=""; G=""; Y=""; R=""; C=""; shift ;;
            *)             die E_USAGE "unknown option '$1' — try --help" 64 ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: AUTO-tcx-cockpit.sh [OPTIONS]

Resolves and validates the inputs for the stage-2 cockpit, then prints the
plan. The worker is checked against LIVE relay state, never a hardcoded list.

Options:
  -w, --worker NAME     target worker
  -s, --session NAME    remote session name; local is <NAME>-cockpit
  -d, --dir PATH        remote working directory for claude
  -n, --dry-run         print every command, run nothing
      --no-color        disable ANSI
  -h, --help            this text

Exit codes:
  0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable · 64 usage

Examples:
  AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
  AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
EOF
}

# ============================================================================
# Preview / run — ONE argv array builds both the dry-run line and the real
# invocation, so they can never drift apart (ergonomic rule 08). Never build a
# conditional flag with `$(cond && echo -n)`: it expands to nothing and turns a
# dry run into a live run (ergonomic rule 01) — arrays only.
# ============================================================================
preview_argv() {  # printf's format is applied ONCE even with zero args, so a
                  # bare `printf ' %q' "$@"` renders an empty argv as " ''".
    (( $# )) || { printf '(empty argv)\n'; return 0; }
    printf '%q' "$1"; shift
    (( $# )) && printf ' %q' "$@"
    printf '\n'
}

run() {  # run argv, or preview it under --dry-run
    if (( DRY )); then printf '  %sDRY%s ' "$Y" "$X" >&2; preview_argv "$@" >&2; return 0; fi
    "$@"
}

# Same, for a command whose STDOUT we need (a pane id). Under --dry-run there
# is no real id, so a clearly-fake one is echoed — it must be obvious in the
# transcript that nothing was created.
run_capture() {
    if (( DRY )); then
        printf '  %sDRY%s ' "$Y" "$X" >&2; preview_argv "$@" >&2
        printf '%%DRY\n'; return 0
    fi
    "$@"
}

# ============================================================================
# Preflight — a missing dependency must be named, never discovered halfway
# through by a cryptic error from a half-built session.
# ============================================================================
preflight() {
    local c
    for c in tmux jq python3; do
        command -v "$c" >/dev/null || die E_MISSING_DEP "'$c' not on PATH — install it" 1
    done
    [[ -x "$TCPUXDO" ]] || die E_MISSING_DEP "tcpuxdo not executable at $TCPUXDO" 1
}

# ============================================================================
# LIVE relay state. The worker list is NEVER hardcoded and NEVER regex-scraped:
# tcpuxdo --op state emits JSON, jq reads it.
#
# THREE-VALUED (the doctor lesson): rc 3 = "cannot tell", which is not the same
# as "no workers". Both callers must keep them apart.
# ============================================================================
STATE_JSON=""
load_state() {
    local out
    out="$("$TCPUXDO" ${RELAY_FLAGS[@]+"${RELAY_FLAGS[@]}"} --op state 2>/dev/null)" || return 3
    jq -e '.ok == true' >/dev/null 2>&1 <<<"$out" || return 3
    STATE_JSON="$out"
    return 0
}

require_state() {
    [[ -n "$STATE_JSON" ]] && return 0
    load_state && return 0
    die E_RELAY_UNREACHABLE \
        "relay ${CONFIG[host]:-${TCPUX_HOST:-?}}:${CONFIG[port]:-${TCPUX_PORT:-?}} did not answer --op state.
  This is CANNOT-TELL, not 'no workers'. Check it with:  tcx-cli doctor" 3
}

worker_list() { jq -r '.state | keys[]' <<<"$STATE_JSON"; }

worker_exists() { jq -e --arg w "$1" '.state | has($w)' >/dev/null <<<"$STATE_JSON"; }

worker_age_secs() {  # seconds since the worker last reported, or "" if never
    jq -r --arg w "$1" '(.state[$w].last_update // 0)' <<<"$STATE_JSON" \
        | awk -v now="$(date +%s)" '{ printf "%d\n", ($1 > 0 ? now - $1 : -1) }'
}

# tcpux's IDENT grammar is [A-Za-z0-9_-]+. A session name outside it is
# rejected by the CS1 axiom on the relay; catching it here names the reason.
validate_session_name() {
    [[ "${CONFIG[session]}" =~ ^[A-Za-z0-9_-]+$ ]] || die E_BAD_SESSION \
        "session '${CONFIG[session]}' is not an IDENT [A-Za-z0-9_-]+ — the relay's CS1 axiom would reject it" 2
}

validate_worker() {
    require_state
    worker_exists "${CONFIG[worker]}" || {
        printf '%scockpit: E_UNKNOWN_WORKER%s no worker named %s in the live registry.\n' \
            "$R" "$X" "${CONFIG[worker]}" >&2
        printf '  %sknown workers:%s\n' "$D" "$X" >&2
        worker_list | sed 's/^/    /' >&2
        exit 2
    }
    local age; age="$(worker_age_secs "${CONFIG[worker]}")"
    if [[ "$age" == "-1" ]]; then
        die E_WORKER_NEVER_REPORTED "worker '${CONFIG[worker]}' has never reported pane state" 2
    elif (( age > ${CONFIG[dead_secs]} )); then
        die E_WORKER_DEAD "worker '${CONFIG[worker]}' has been silent ${age}s (> ${CONFIG[dead_secs]}s).
  Submitting would queue an op nobody runs — which looks exactly like success.
  Raise the bar with TCX_COCKPIT_DEAD_SECS if you know better." 2
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    parse_args "$@"
    build_relay_flags
    preflight

    [[ -n "${CONFIG[session]}" ]] && validate_session_name
    [[ -n "${CONFIG[worker]}"  ]] && validate_worker

    printf '\n%s── cockpit ──%s\n' "$B" "$X"
    printf '  %sworker%s          %s\n' "$D" "$X" "${CONFIG[worker]:-(unset)}"
    printf '  %sremote session%s  %s\n' "$D" "$X" "${CONFIG[session]:-(unset)}"
    printf '  %sremote dir%s      %s\n' "$D" "$X" "${CONFIG[dir]:-(unset)}"
    printf '  %sdry run%s         %s\n' "$D" "$X" "$DRY"
    printf '  %sengine%s          %s\n' "$D" "$X" "$TCPUXDO"
}

main "$@"
