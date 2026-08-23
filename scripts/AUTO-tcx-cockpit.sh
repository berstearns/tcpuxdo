#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-cockpit.sh — skeleton of the stage-2 cockpit CLI: the option
#          surface, the dry-run preview machinery, and the named-error contract.
#          It resolves its inputs and prints the plan. It builds nothing yet.
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
#          TCX_COCKPIT_DIR.
#
# OUTPUTS / SIDE EFFECTS:
#          stdout only. Nothing is created, nothing is sent, no file is written.
#          exit 0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable
#          · 64 usage error.
#
# USAGE (combinatorial):
#   AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
#       # resolve the three inputs and print the plan
#   AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
#       # the same, in dry-run mode
#   AUTO-tcx-cockpit.sh --nonsense
#       # INVALID: unknown option, exit 64
#
# NOT IN THIS COMMIT, on purpose: the relay preflight, the rofi prompts, the
#          remote session, and the local cockpit. Each lands as its own rung so
#          it can be reverted without taking the option surface with it.
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
)

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

Resolves the inputs for the stage-2 cockpit and prints the plan.

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
# Main
# ============================================================================
main() {
    parse_args "$@"

    printf '\n%s── cockpit ──%s\n' "$B" "$X"
    printf '  %sworker%s          %s\n' "$D" "$X" "${CONFIG[worker]:-(unset)}"
    printf '  %sremote session%s  %s\n' "$D" "$X" "${CONFIG[session]:-(unset)}"
    printf '  %sremote dir%s      %s\n' "$D" "$X" "${CONFIG[dir]:-(unset)}"
    printf '  %sdry run%s         %s\n' "$D" "$X" "$DRY"
    printf '  %sengine%s          %s\n' "$D" "$X" "$TCPUXDO"
}

main "$@"
