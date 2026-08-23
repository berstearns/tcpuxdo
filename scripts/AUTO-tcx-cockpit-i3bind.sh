#!/usr/bin/env bash
#===============================================================================
# WHAT:    Prints the i3 `bindsym` line for AUTO-tcx-cockpit.sh and reports
#          every existing binding it would collide with. READ-ONLY: it never
#          edits the i3 config.
#
# WHY:     The i3 config lives in a DIFFERENT repo
#          (/home/b/p/pn/os_configs/i3/config) and is not this project's to
#          change. But "here is a line, paste it somewhere" is how a keybinding
#          silently shadows one the user already has: i3 keeps the LAST bindsym
#          for a key and says nothing. So the claim "this key is free" has to be
#          produced by a program that can be re-run, not asserted in a report
#          that scrolls away (claude-rules: every command is a tracked local
#          program, never an inline snippet).
#
# INPUTS:  -k, --key COMBO     key combination to check (default: $mod+Ctrl+c)
#          -c, --config PATH   i3 config to check against
#                              (default: /home/b/p/pn/os_configs/i3/config)
#          -h, --help
#
# OUTPUTS / SIDE EFFECTS:
#          stdout: the bindsym line, then the collision verdict.
#          NOTHING is written. The i3 config is opened read-only.
#          exit 0 the key is free · 1 the key is TAKEN · 2 config unreadable
#
# USAGE (combinatorial):
#   ./scripts/AUTO-tcx-cockpit-i3bind.sh
#       # the default proposal, checked
#   ./scripts/AUTO-tcx-cockpit-i3bind.sh -k '$mod+Ctrl+Shift+c'
#       # check an alternative before suggesting it
#   ./scripts/AUTO-tcx-cockpit-i3bind.sh -c /etc/i3/config
#       # check against a different config
#
# RE-RUN SAFETY: read-only, idempotent, safe to run any number of times.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COCKPIT="$HERE/AUTO-tcx-cockpit.sh"

declare -A CONFIG=(
    [key]="${TCX_COCKPIT_I3_KEY:-\$mod+Ctrl+c}"
    [config]="${TCX_COCKPIT_I3_CONFIG:-/home/b/p/pn/os_configs/i3/config}"
)

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   show_help; exit 0 ;;
            -k|--key)    CONFIG[key]="$2"; shift 2 ;;
            -c|--config) CONFIG[config]="$2"; shift 2 ;;
            *) echo "unknown option '$1' — try --help" >&2; exit 64 ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: AUTO-tcx-cockpit-i3bind.sh [-k COMBO] [-c CONFIG]

Prints the i3 bindsym line for the cockpit and names every binding it would
collide with. Read-only — it never edits the i3 config.

  -k, --key COMBO     key combination (default: ${CONFIG[key]})
  -c, --config PATH   i3 config (default: ${CONFIG[config]})
  -h, --help

Exit: 0 key free · 1 key TAKEN · 2 config unreadable
EOF
}

# i3 keeps the LAST bindsym for a key, so a collision is silent by design.
#
# The match is a FIELD EQUALITY in awk, deliberately not a regex. The first
# version of this function built an ERE out of the key and reported
# "$mod+Ctrl+c is not bound" while line 347 of the very same file bound it: in
# an ERE, `+` is the one-or-more quantifier, so `Ctrl+c` matches `Ctrlc` and
# `Ctrllc` but never the literal `Ctrl+c`. That is the whole failure this
# script exists to prevent, produced by the script itself — an observer broken
# in a way that acquits every subject (ergonomic-cli-entrypoints rule 07).
# Nothing here may treat the key as a pattern.
find_collisions() {  # $1 key ; prints "<lineno>:<line>" per hit
    awk -v key="$1" '
        { line = $0
          sub(/^[[:space:]]+/, "", line)
          n = split(line, f, /[[:space:]]+/)
          if (n >= 2 && f[1] == "bindsym" && f[2] == key) printf "%d:%s\n", NR, $0 }
    ' "${CONFIG[config]}" 2>/dev/null
}

main() {
    parse_args "$@"
    [[ -r "${CONFIG[config]}" ]] || { echo "i3 config not readable: ${CONFIG[config]}" >&2; exit 2; }

    printf 'Add this line to %s:\n\n' "${CONFIG[config]}"
    printf '    bindsym %s exec --no-startup-id %s\n\n' "${CONFIG[key]}" "$COCKPIT"

    local hits
    hits="$(find_collisions "${CONFIG[key]}")"
    if [[ -n "$hits" ]]; then
        printf 'COLLISION: %s is ALREADY BOUND in that file:\n' "${CONFIG[key]}"
        printf '%s\n' "$hits" | sed 's/^/    /'
        printf '\ni3 keeps the LAST bindsym for a key and prints no warning, so pasting the\n'
        printf 'line above would silently shadow the binding(s) shown. Pick a free key.\n'
        exit 1
    fi
    printf 'No collision: %s is not bound in %s.\n' "${CONFIG[key]}" "${CONFIG[config]}"
    exit 0
}

main "$@"
