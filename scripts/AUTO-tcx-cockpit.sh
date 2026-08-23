#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-cockpit.sh — one command (and therefore one i3 shortcut)
#          that gives you a REMOTE Claude Code pane plus a LOCAL two-pane
#          cockpit for driving it:
#
#            remote worker :   tmux session <name>, one pane running `claude`
#            local m1      :   tmux session <name>-cockpit
#                                pane "tcx-send"   — you type here
#                                pane "tcx-stream" — live view of the remote pane
#
# WHY:     Stage 1 gave us the pieces: `tcpuxdo` submits ops, `tcx-cli` resolves
#          addresses and sends, `setup/tcx-stream.sh` mirrors a remote pane.
#          Driving a remote Claude session still cost six manual steps in three
#          different surfaces, in an order you had to remember, and getting the
#          order wrong left half a session behind. This file is ORCHESTRATION
#          ONLY: it dispatches to those engines and reimplements none of them.
#          In particular there is NO capture loop in this file — that is
#          setup/tcx-stream.sh, and it is run as the stream pane's command.
#
# INPUTS:  -w, --worker NAME    target worker (else: rofi over LIVE state)
#          -s, --session NAME   remote session name; local becomes <name>-cockpit
#          -d, --dir PATH       remote working directory for claude
#          -p, --profile NAME   named preset from the profiles file
#          -n, --dry-run        print every tcpuxdo/tmux argv, run NOTHING
#              --no-remote      build only the local cockpit
#              --no-local       create only the remote session
#              --rebuild        kill an existing local cockpit and rebuild it
#              --teardown       kill the local cockpit and exit (remote is left)
#              --tty            force plain tty prompts (never rofi)
#          -h, --help
#              --version
#
#          Input mode auto-detects: DISPLAY set + rofi on PATH -> rofi prompts;
#          otherwise (or with --tty) plain read prompts, answers acceptable
#          piped on stdin.
#
#          Env overrides (every CONFIG key): TCX_COCKPIT_WORKER,
#          TCX_COCKPIT_SESSION, TCX_COCKPIT_DIR, TCX_COCKPIT_PROFILE,
#          TCX_COCKPIT_PROFILES_FILE, TCX_COCKPIT_CLAUDE_CMD,
#          TCX_COCKPIT_SHORTCUT, TCX_COCKPIT_DEAD_SECS, TCX_COCKPIT_WAIT,
#          TCX_COCKPIT_ROFI_LINES.
#
# OUTPUTS / SIDE EFFECTS:
#          remote: create-session / create-pane / send-keys on ONE worker,
#                  plus a `tcpuxdo shortcut set claude-main` naming that pane.
#          local:  a tmux session <name>-cockpit with two TITLED panes.
#          writes: ${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/target
#                  (the SHARED target file, format "worker<TAB>pane", exactly
#                  the format tcx.sh writes — see save_target there). Only the
#                  remote half writes it; --no-remote never touches it.
#          exit 0 ok · 1 runtime failure · 2 bad input (unknown worker, …)
#          · 3 relay unreachable (CANNOT TELL) · 64 usage error.
#
# USAGE (combinatorial):
#   AUTO-tcx-cockpit.sh
#       # rofi asks for worker (from LIVE state), session, dir — then both halves
#   AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
#       # fully specified, no prompt at all — the i3-shortcut-friendly form
#   AUTO-tcx-cockpit.sh -p ferret
#       # the same, from a saved profile
#   AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
#       # dry run: prints every tcpuxdo and tmux argv, creates nothing
#   AUTO-tcx-cockpit.sh --no-remote -s ferret
#       # only the local cockpit (remote session already exists)
#   AUTO-tcx-cockpit.sh --no-local -w newlaptop -s ferret -d '~/p/ferret'
#       # only the remote session (you already have a cockpit open)
#   AUTO-tcx-cockpit.sh --teardown -s ferret
#       # kill the LOCAL cockpit; the remote claude session keeps running
#   AUTO-tcx-cockpit.sh --no-remote --no-local
#       # INVALID: nothing left to do, exit 64
#
# RE-RUN SAFETY: idempotent by construction.
#          remote — create-session is skipped when the session already exists in
#                   the registry; the claude pane is REUSED, never duplicated,
#                   and `cd … && claude` is only sent into a pane that is not
#                   already running claude.
#          local  — an existing <name>-cockpit with the two titled panes is
#                   REUSED. A malformed one is a NAMED error pointing at
#                   --rebuild; it is never silently duplicated or repaired.
#          A send is never retried automatically.
#
# PANE ADDRESSING: never `session:window.index` — indexes re-map on every split.
#          Panes are created with `-P -F '#{pane_id}'`, titled with
#          `select-pane -T`, and re-found by TITLE. A duplicate title is a hard
#          error, never a `head -1` guess (~/.claude/rules/tmux-pane-routing.md).
#===============================================================================

set -uo pipefail   # NOT -e: exit codes are handled explicitly, everywhere.

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TCPUXDO="$REPO/tcpuxdo"
STREAM="$REPO/setup/tcx-stream.sh"

# ============================================================================
# CONFIG: env-var overridable, so one i3 binding can be re-purposed
#   bindsym $mod+Ctrl+Shift+c exec --no-startup-id \
#       TCX_COCKPIT_WORKER=newlaptop /home/b/p/tcpuxdo/scripts/AUTO-tcx-cockpit.sh
# ============================================================================
declare -A CONFIG=(
    [worker]="${TCX_COCKPIT_WORKER:-}"
    [session]="${TCX_COCKPIT_SESSION:-}"
    [dir]="${TCX_COCKPIT_DIR:-}"
    [profile]="${TCX_COCKPIT_PROFILE:-}"
    [profiles_file]="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
    # The command the remote pane ends up running. Overridable because a node
    # may need `claude --dangerously-skip-permissions` or a wrapper.
    [claude_cmd]="${TCX_COCKPIT_CLAUDE_CMD:-claude}"
    # A tcpuxdo SHORTCUT is the only stable, protocol-supported name for a
    # remote pane today — the worker does not sync #{pane_title}. See
    # docs/cockpit.md "The one thing the protocol cannot do".
    [shortcut]="${TCX_COCKPIT_SHORTCUT:-claude-main}"
    # A worker silent longer than this is treated as DEAD: submitting to it
    # queues an op nobody will ever run, which looks exactly like success.
    [dead_secs]="${TCX_COCKPIT_DEAD_SECS:-180}"
    # Seconds to wait for the registry to reflect a session/pane we created.
    [wait]="${TCX_COCKPIT_WAIT:-25}"
    [rofi_lines]="${TCX_COCKPIT_ROFI_LINES:-12}"
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
DO_REMOTE=1
DO_LOCAL=1
REBUILD=0
TEARDOWN=0
FORCE_TTY=0
PRINT_TARGET=0
VERSION="1.2.0"

# The one flag list, used by --help, the parser cases above it, and the
# completion generator — so completion can never drift from the parser.
ALL_FLAGS="-w --worker -s --session -d --dir -p --profile -n --dry-run
--no-remote --no-local --rebuild --teardown --tty --print-target --no-color
-h --help --version"

# Local pane titles. Fixed, because the selfcheck and docs both name them.
SEND_TITLE="tcx-send"
STREAM_TITLE="tcx-stream"

# The SHARED target file. Deliberately NOT namespaced by TCX_GROUP: this is the
# file setup/tcx-stream.sh reads (it hardcodes the ungrouped path), so writing a
# grouped one would leave the stream pane showing "no target set" forever.
TARGET_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/target"

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
            -p|--profile)  [[ $# -ge 2 ]] || die E_USAGE "-p needs a value" 64
                           CONFIG[profile]="$2"; shift 2 ;;
            -n|--dry-run)  DRY=1; shift ;;
            --no-remote)   DO_REMOTE=0; shift ;;
            --no-local)    DO_LOCAL=0; shift ;;
            --rebuild)     REBUILD=1; shift ;;
            --teardown)    TEARDOWN=1; shift ;;
            --tty)         FORCE_TTY=1; shift ;;
            --print-target) PRINT_TARGET=1; shift ;;
            --version)     printf 'AUTO-tcx-cockpit.sh %s\n' "$VERSION"; exit 0 ;;
            completion)    [[ $# -ge 2 ]] || die E_USAGE "completion needs a shell: bash or zsh" 64
                           emit_completion "$2"; exit 0 ;;
            --no-color)    B=""; D=""; X=""; G=""; Y=""; R=""; C=""; shift ;;
            *)             die E_USAGE "unknown option '$1' — try --help" 64 ;;
        esac
    done
}

# ============================================================================
# Tab completion (GNU ergonomics §11). Generated from ALL_FLAGS — the same
# list --help prints — and completes VALUES for -w/--worker from live relay
# state at completion time (never a hardcoded worker list).
# ============================================================================
emit_completion() {  # $1 bash|zsh
    local self="$HERE/$(basename "${BASH_SOURCE[0]}")"
    local flags_one_line; flags_one_line="$(tr '\n' ' ' <<<"$ALL_FLAGS")"
    case "$1" in
        bash) cat <<EOF
# bash completion for AUTO-tcx-cockpit.sh — generated by 'completion bash'
# install:  AUTO-tcx-cockpit.sh completion bash > ~/.local/share/bash-completion/completions/AUTO-tcx-cockpit.sh
_tcx_cockpit() {
    local cur prev
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    case "\$prev" in
        -w|--worker)
            local workers
            workers="\$("$REPO/tcpuxdo" --op state 2>/dev/null \\
                | jq -r '.state | keys[]' 2>/dev/null)"
            COMPREPLY=( \$(compgen -W "\$workers" -- "\$cur") ); return ;;
        -d|--dir)  COMPREPLY=( \$(compgen -d -- "\$cur") ); return ;;
        -s|--session|-p|--profile) COMPREPLY=(); return ;;
    esac
    COMPREPLY=( \$(compgen -W "$flags_one_line completion" -- "\$cur") )
}
complete -F _tcx_cockpit AUTO-tcx-cockpit.sh $self
EOF
        ;;
        zsh) cat <<EOF
#compdef AUTO-tcx-cockpit.sh
# zsh completion for AUTO-tcx-cockpit.sh — generated by 'completion zsh'
# install:  AUTO-tcx-cockpit.sh completion zsh > ~/.zsh/completions/_AUTO-tcx-cockpit
_tcx_cockpit() {
    local -a workers
    case "\$words[CURRENT-1]" in
        -w|--worker)
            workers=( \${(f)"\$("$REPO/tcpuxdo" --op state 2>/dev/null \\
                | jq -r '.state | keys[]' 2>/dev/null)"} )
            _describe 'worker' workers; return ;;
        -d|--dir) _directories; return ;;
    esac
    _arguments \$(printf -- "'%s' " $flags_one_line completion)
}
_tcx_cockpit "\$@"
EOF
        ;;
        *) die E_USAGE "unknown shell '$1' — completion supports: bash zsh" 64 ;;
    esac
}

show_help() {
    cat <<EOF
Usage: AUTO-tcx-cockpit.sh [OPTIONS]

One command → a remote Claude Code pane on a tcpuxdo worker, plus a local
two-pane tmux cockpit (send + live stream) aimed at it.

Options:
  -w, --worker NAME     target worker (skip the rofi prompt)
  -s, --session NAME    remote session name; local is <NAME>-cockpit
  -d, --dir PATH        remote working directory for claude
  -p, --profile NAME    named preset from ${CONFIG[profiles_file]}
  -n, --dry-run         print every tmux/tcpuxdo command, run nothing
      --no-remote       only build the local cockpit
      --no-local        only create the remote session
      --rebuild         kill an existing local cockpit and rebuild it
      --teardown        kill the local cockpit and exit (remote keeps running)
      --tty             force plain tty prompts (never rofi)
      --print-target    print the saved target (worker<TAB>pane) on stdout, exit
      --no-color        disable ANSI
  -h, --help            this text
      --version         print the version and exit

Subcommands:
  completion bash|zsh   print a tab-completion script (completes worker names
                        from live relay state); install hint is in the output

Anything not given on the CLI is asked for. Input mode auto-detects: rofi when
\$DISPLAY is set and rofi is on PATH, plain read prompts otherwise (--tty
forces the latter). The worker list always comes from LIVE relay state
(tcpuxdo --op state), never a hardcoded list.

Profiles file (${CONFIG[profiles_file]}), one per line:
  # name:worker:session:dir
  ferret:newlaptop:ferret:~/p/ferret

Exit codes:
  0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable · 64 usage

Examples:
  AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
  AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
  AUTO-tcx-cockpit.sh -p ferret
  AUTO-tcx-cockpit.sh --no-remote -s ferret
  AUTO-tcx-cockpit.sh --teardown -s ferret
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
# Profiles — named presets so an i3 binding stays declarative
# ============================================================================
apply_profile() {
    local name="${CONFIG[profile]}"
    [[ -z "$name" ]] && return 0
    local file="${CONFIG[profiles_file]}"
    [[ -r "$file" ]] || die E_NO_PROFILES "profiles file not readable: $file" 2
    local line
    line="$(grep -v '^[[:space:]]*#' "$file" | grep -m1 "^${name}:")" \
        || die E_NO_PROFILE "no profile '$name' in $file" 2
    local p_worker p_session p_dir
    IFS=':' read -r _ p_worker p_session p_dir <<<"$line"
    # CLI beats profile: a flag the human typed is never overwritten by a file.
    [[ -z "${CONFIG[worker]}"  && -n "${p_worker:-}"  ]] && CONFIG[worker]="$p_worker"
    [[ -z "${CONFIG[session]}" && -n "${p_session:-}" ]] && CONFIG[session]="$p_session"
    [[ -z "${CONFIG[dir]}"     && -n "${p_dir:-}"     ]] && CONFIG[dir]="$p_dir"
    return 0
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
    [[ -r "$STREAM"  ]] || die E_MISSING_ENGINE \
        "setup/tcx-stream.sh missing at $STREAM — the stream pane would have nothing to run" 1
    # tcx-cli is what the human types in the send pane; if it is absent the
    # cockpit still works, but the printed next-step command would be a lie.
    TCX_CLI="$(command -v tcx-cli 2>/dev/null)"
    [[ -n "$TCX_CLI" ]] || { [[ -x "$REPO/tcx-cli" ]] && TCX_CLI="$REPO/tcx-cli"; }
    [[ -n "$TCX_CLI" ]] || TCX_CLI="$HERE/AUTO-tcx-cli.sh"
    [[ -x "$TCX_CLI" || -r "$TCX_CLI" ]] \
        || die E_MISSING_DEP "tcx-cli not found (PATH, $REPO/tcx-cli, $HERE/AUTO-tcx-cli.sh)
  fix:  bash $HERE/AUTO-tcx-cli.sh install" 1
    # rofi is only load-bearing when something still has to be asked for AND the
    # rofi frontend was selected. It is checked here (named, once) rather than
    # at the prompt, where a missing binary would look like a cancelled prompt.
    # With no X display (or --tty) the fallback is plain read prompts, which
    # need no dependency at all — see prompts_via_rofi / tty_pick / tty_ask.
    # Only the inputs this run will actually COLLECT count as missing: the
    # worker and the dir exist only on the remote path (mirror collect_inputs).
    local need_input=0
    [[ -z "${CONFIG[session]}" ]] && need_input=1
    if (( DO_REMOTE && ! TEARDOWN )); then
        [[ -z "${CONFIG[worker]}" || -z "${CONFIG[dir]}" ]] && need_input=1
    fi
    if (( need_input )); then
        if prompts_via_rofi; then
            :   # rofi confirmed present by prompts_via_rofi itself
        elif [[ ! -t 0 && ! -p /dev/stdin && ! -f /dev/stdin ]]; then
            die E_MISSING_DEP \
                "an input is missing, no rofi frontend, and stdin is closed — pass -w/-s/-d explicitly (or pipe answers with --tty)" 1
        fi
    fi
}

# Frontend decision, made in ONE place: rofi only under X, with rofi on PATH,
# and not overridden by --tty. Everything else is a plain-tty prompt.
prompts_via_rofi() {
    (( FORCE_TTY )) && return 1
    [[ -n "${DISPLAY:-}" ]] && command -v rofi >/dev/null
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

# Pane ids belonging to one session on one worker, sorted.
session_panes() {  # $1 worker  $2 session
    jq -r --arg w "$1" --arg s "$2" \
       '(.state[$w].panes // {}) | keys[] | select(startswith($s + ":"))' <<<"$STATE_JSON" \
       | sort
}

pane_cmd() {  # $1 worker  $2 pane
    jq -r --arg w "$1" --arg p "$2" '(.state[$w].panes[$p].cmd // "")' <<<"$STATE_JSON"
}

# ============================================================================
# Input collection — rofi, but only for what is still missing. Kept inline
# (≈30 lines) rather than split into AUTO-tcx-cockpit-rofi.sh: a second file
# that is only ever called from one place earns nothing.
# ============================================================================
# NOTE: no `</dev/null` here. rofi -dmenu reads its OPTION LIST from stdin, so
# a trailing `</dev/null` replaces the piped options with an empty list and the
# user gets a menu with zero entries ("no worker appears"). The pipe IS the
# option list; a piped caller of the cockpit cannot leak into it because the
# printf side is generated, not inherited.
rofi_pick() {  # $1 prompt  $2.. options
    printf '%s\n' "${@:2}" | rofi -dmenu -i -p "$1" -lines "${CONFIG[rofi_lines]}"
}

rofi_ask() {  # $1 prompt  $2 default ; free text
    printf '%s\n' "$2" | rofi -dmenu -i -p "$1" -lines 1
}

# Plain-tty twins of the rofi prompts. The menu goes to STDERR (stdout stays
# data-only); the answer is read from STDIN, so a piped caller can supply the
# answers non-interactively (`printf 'w\ns\n~\n' | … --tty`). EOF = cancelled.
tty_pick() {  # $1 prompt  $2.. options ; a number picks, anything else is literal
    local n=$(( $# - 1 )) i=1 opt reply
    { printf '%s:\n' "$1"
      for opt in "${@:2}"; do printf '  %d) %s\n' "$i" "$opt"; i=$((i+1)); done
      printf '%s (number or name): ' "$1"; } >&2
    IFS= read -r reply || return 1
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= n )); then
        printf '%s\n' "${@:$((reply+1)):1}"
    else
        printf '%s\n' "$reply"
    fi
}

tty_ask() {  # $1 prompt  $2 default
    printf '%s [%s]: ' "$1" "$2" >&2
    local reply
    IFS= read -r reply || return 1
    printf '%s\n' "${reply:-$2}"
}

ui_pick() { if prompts_via_rofi; then rofi_pick "$@"; else tty_pick "$@"; fi }
ui_ask()  { if prompts_via_rofi; then rofi_ask  "$@"; else tty_ask  "$@"; fi }

collect_inputs() {
    # The worker (like the dir) is only meaningful on the remote path; asking
    # for it under --no-remote would dial the relay for an unused answer.
    if [[ -z "${CONFIG[worker]}" && "$DO_REMOTE" == 1 ]]; then
        require_state
        local -a workers=()
        mapfile -t workers < <(worker_list)
        (( ${#workers[@]} )) || die E_NO_WORKERS \
            "no worker has ever registered with the relay — bring one up with setup/node-up.sh" 2
        CONFIG[worker]="$(ui_pick "worker" "${workers[@]}")"
        [[ -n "${CONFIG[worker]}" ]] || die E_CANCELLED "no worker chosen" 2
    fi
    if [[ -z "${CONFIG[session]}" ]]; then
        CONFIG[session]="$(ui_ask "remote session name" "claude")"
        [[ -n "${CONFIG[session]}" ]] || die E_CANCELLED "no session name given" 2
    fi
    if [[ -z "${CONFIG[dir]}" && "$DO_REMOTE" == 1 ]]; then
        CONFIG[dir]="$(ui_ask "remote working dir" "~")"
        [[ -n "${CONFIG[dir]}" ]] || die E_CANCELLED "no working directory given" 2
    fi
}

# The remote directory is INTERPOLATED into a shell command that runs on the
# worker: `cd <dir> && claude`. Nominally the argument is a directory; without a
# grammar its actual domain is arbitrary shell, because `-d '~ && curl … | sh'`
# is a perfectly good string. An operation whose stated domain and real domain
# differ that far is an unbounded primitive — a general-purpose escape into raw
# code — and bounding it is the whole point of naming the domain first
# (docs/cockpit-algebra.md, R4).
#
# A POSITIVE grammar, not a blocklist: every shell metacharacter is absent
# because only these characters are present. That is also what makes the
# unquoted `cd <dir>` safe, and unquoted is required — `cd '~/p/x'` would not
# expand the tilde.
validate_dir() {
    [[ -n "${CONFIG[dir]}" ]] || return 0
    [[ "${CONFIG[dir]}" =~ ^[A-Za-z0-9_.~/+-]+$ ]] || die E_BAD_DIR \
        "remote dir '${CONFIG[dir]}' has characters outside [A-Za-z0-9_.~/+-].
  It is interpolated into 'cd <dir> && ${CONFIG[claude_cmd]}' on the worker, so a
  space or a shell metacharacter there is arbitrary remote code, not a path." 2
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
# REMOTE HALF — create-session → create-pane → send-keys, in that order, each
# step skipped when the registry already shows its effect (idempotency).
# ============================================================================

# Block until the registry shows at least one pane for the session. tmux assigns
# pane indices, so the created pane id is DISCOVERED, never assumed (AXIOMS.md,
# "the sender must re-read state after the update").
wait_for_session_pane() {  # $1 worker  $2 session -> prints the first pane id
    local deadline=$(( $(date +%s) + ${CONFIG[wait]} )) panes
    while :; do
        load_state || return 3
        panes="$(session_panes "$1" "$2")"
        [[ -n "$panes" ]] && { head -1 <<<"$panes"; return 0; }
        (( $(date +%s) >= deadline )) && return 1
        sleep 1
    done
}

remote_half() {
    local w="${CONFIG[worker]}" s="${CONFIG[session]}" existing pane

    require_state
    existing="$(session_panes "$w" "$s")"

    if [[ -z "$existing" ]]; then
        step "remote: create-session $s on $w"
        run "$TCPUXDO" ${RELAY_FLAGS[@]+"${RELAY_FLAGS[@]}"} --op create-session --worker "$w" --session "$s" >/dev/null \
            || die E_CREATE_SESSION "create-session '$s' on '$w' was rejected — run it by hand to see the axiom:
  $TCPUXDO --op create-session --worker $w --session $s" 1
        if (( DRY )); then
            pane="$s:0:0"
            note "dry-run: assuming the created pane would be $pane (tmux assigns the real index)"
        else
            pane="$(wait_for_session_pane "$w" "$s")" || die E_PANE_NEVER_APPEARED \
                "session '$s' never showed a pane in the registry within ${CONFIG[wait]}s.
  The op was accepted but the worker may be wedged:  tcx-cli doctor" 1
        fi
    else
        pane="$(head -1 <<<"$existing")"
        note "remote session '$s' already exists on $w — reusing pane $pane (no duplicate created)"
    fi

    # create-pane: only when the session somehow has no pane we can use. On a
    # fresh create-session tmux already made one, and adding a second pane per
    # run is exactly the silent duplication the idempotency constraint forbids.
    if [[ -z "$pane" ]]; then
        step "remote: create-pane $s:0:0 on $w"
        run "$TCPUXDO" ${RELAY_FLAGS[@]+"${RELAY_FLAGS[@]}"} --op create-pane --worker "$w" --pane "$s:0:0" >/dev/null \
            || die E_CREATE_PANE "create-pane '$s:0:0' on '$w' was rejected" 1
        pane="$(wait_for_session_pane "$w" "$s")" || die E_PANE_NEVER_APPEARED \
            "create-pane accepted but no pane appeared for '$s' within ${CONFIG[wait]}s" 1
    fi

    REMOTE_PANE="$pane"

    # A STABLE NAME for the pane. The worker syncs session/window/pane/cmd/pid
    # but NOT #{pane_title}, so "the pane titled claude-main" is not addressable
    # over this protocol (README, "Title-based addressing … is not wired in").
    # A tcpuxdo SHORTCUT is the protocol's own stable alias and needs no engine
    # change — see docs/cockpit.md for why we did not touch the protocol.
    step "remote: shortcut ${CONFIG[shortcut]} -> $w $pane"
    run "$TCPUXDO" ${RELAY_FLAGS[@]+"${RELAY_FLAGS[@]}"} --op shortcut-set --name "${CONFIG[shortcut]}" \
        --worker "$w" --pane "$pane" --force >/dev/null \
        || note "shortcut '${CONFIG[shortcut]}' could not be set (continuing; addressing by pane id still works)"

    # Launch claude — but only if that pane is not already running it. Sending
    # `cd … && claude` into a live claude pane types the text INTO Claude.
    local cur; cur="$(pane_cmd "$w" "$pane")"
    if [[ "$cur" == "claude" ]]; then
        note "pane $pane already runs claude — not sending a second launch"
    else
        step "remote: send-keys 'cd ${CONFIG[dir]} && ${CONFIG[claude_cmd]}' -> $w $pane"
        run "$TCPUXDO" ${RELAY_FLAGS[@]+"${RELAY_FLAGS[@]}"} --no-cascade -w "$w" -p "$pane" \
            -c "cd ${CONFIG[dir]} && ${CONFIG[claude_cmd]}" >/dev/null \
            || die E_SEND_FAILED "send-keys into $w $pane was rejected (busy pane? SK5) — check:
  $TCPUXDO list $w" 1
    fi

    save_target "$w" "$pane"
}

# The target file, written in EXACTLY the format tcx.sh's save_target writes:
# one line, "worker<TAB>pane". tcx-stream.sh and tcx-cli both read this file;
# inventing a second format here would silently break both.
save_target() {  # $1 worker  $2 pane
    local prev=""
    [[ -s "$TARGET_FILE" ]] && prev="$(tr '\t' ' ' < "$TARGET_FILE" | tr -d '\n')"
    if (( DRY )); then
        printf '  %sDRY%s would write %s <- %s\t%s\n' "$Y" "$X" "$TARGET_FILE" "$1" "$2" >&2
        return 0
    fi
    mkdir -p "$(dirname "$TARGET_FILE")"
    printf '%s\t%s\n' "$1" "$2" > "$TARGET_FILE"
    # The target file is SHARED (tcx.sh, tcx-cli, tcx-stream.sh all read it).
    # Overwriting it silently is the 2026-07-21 redirect incident; print the old
    # value so it is one copy-paste to put back.
    [[ -n "$prev" ]] && note "target was: $prev  (restore with: tcx-cli to $prev)"
    step "target: $1 $2  ->  $TARGET_FILE"
}

# ============================================================================
# LOCAL HALF — the two-pane cockpit.
#
# Panes are addressed by %ID throughout. `session:window.index` is never used:
# indexes re-map on every split, and the pane that ends up at .1 after a split
# is not the pane that was there before it (~/.claude/rules/tmux-pane-routing.md).
# ============================================================================
local_session_name() { printf '%s-cockpit\n' "${CONFIG[session]}"; }

session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

# Resolve a pane by TITLE inside one session. Zero hits and MORE THAN ONE hit
# are both errors — a duplicate title is never resolved by taking the first.
pane_by_title() {  # $1 session  $2 title
    local hits n
    hits="$(tmux list-panes -s -t "=$1" -F '#{pane_id}	#{pane_title}' 2>/dev/null \
            | awk -F'\t' -v t="$2" '$2 == t { print $1 }')"
    n="$(printf '%s' "$hits" | grep -c . || true)"
    case "$n" in
        1) printf '%s\n' "$hits"; return 0 ;;
        0) return 1 ;;
        *) printf 'cockpit: E_DUPLICATE_TITLE %s panes in %s are titled %s:\n%s\n' \
               "$n" "$1" "$2" "$hits" >&2; return 2 ;;
    esac
}

# A freshly-created pane is NOT ready for keystrokes: the shell's rc files are
# still running, and anything sent before the first prompt is swallowed with no
# error at all. Observed here: the staged line landed in a pane whose
# pane_current_command was still `mkdir` (a zshrc line), and the pane came up
# empty. Wait for a known shell before typing anything.
#
# "Any shell-looking command" is NOT the test. Observed here a second time: a
# zshrc line spawns a short-lived `bash`, the first sample read `bash`, and the
# nocorrect decision (constraint 4) was taken for the wrong shell. The pane's
# shell is tmux's default-shell; wait for THAT, and for two identical samples,
# so a transient child cannot answer for it.
wait_for_shell() {  # $1 pane %ID -> prints the shell name, rc 1 on timeout
    local pane="$1" deadline=$(( $(date +%s) + 10 )) cur prev="" want
    want="$(basename "$(tmux show-options -gv default-shell 2>/dev/null || echo "${SHELL:-bash}")")"
    while :; do
        cur="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"
        [[ "$cur" == "$want" && "$prev" == "$want" ]] && { printf '%s\n' "$cur"; return 0; }
        prev="$cur"
        (( $(date +%s) >= deadline )) && { printf '%s\n' "${cur:-unknown}"; return 1; }
        sleep 0.2
    done
}

# Stage a line in a pane WITHOUT running it. `send-keys -l` sends the argument
# LITERALLY; without -l tmux reads it as key NAMES and any ';' or the word
# 'Enter' inside it is mangled into a keypress.
stage_line() {  # $1 pane %ID  $2 literal text
    local pane="$1" text="$2" shell
    if (( DRY )); then
        # There is no pane to interrogate in a dry run, and printing the
        # UNPREFIXED line would preview a command different from the one that
        # would run. Fall back to the login shell, which is what the pane would
        # have started (ergonomic rule 08: preview the command that acts).
        shell="$(basename "${SHELL:-bash}")"
    else
        shell="$(wait_for_shell "$pane")" || {
            note "pane $pane never reached a shell prompt (saw '$shell') — not staging a command there"
            return 0
        }
    fi
    # oh-my-zsh's ENABLE_CORRECTION turns a mistyped word into a blocking
    # `correct 'x' to 'y'? [nyae]` prompt. `nocorrect` disarms it — and is a
    # SYNTAX ERROR in bash, so it is only prefixed when the pane really is zsh.
    [[ "$shell" == "zsh" ]] && text="nocorrect $text"
    run tmux send-keys -t "$pane" -l "$text"
}

teardown_local() {
    local sess; sess="$(local_session_name)"
    if ! session_exists "$sess"; then
        note "no local session '$sess' to tear down"
        return 0
    fi
    step "local: kill-session $sess"
    run tmux kill-session -t "=$sess" || die E_TEARDOWN "could not kill '$sess'" 1
}

local_half() {
    local sess; sess="$(local_session_name)"

    if session_exists "$sess"; then
        if (( REBUILD )); then
            step "local: --rebuild — killing existing $sess"
            run tmux kill-session -t "=$sess" || die E_TEARDOWN "could not kill '$sess'" 1
        else
            # Reuse, but only if it is the cockpit we would have built. A
            # half-built session silently reused is worse than a named error.
            local sp st rc=0
            sp="$(pane_by_title "$sess" "$SEND_TITLE")"   || rc=$?
            st="$(pane_by_title "$sess" "$STREAM_TITLE")" || rc=$?
            if (( rc == 0 )) && [[ -n "$sp" && -n "$st" ]]; then
                LOCAL_SEND_PANE="$sp"; LOCAL_STREAM_PANE="$st"
                note "local session '$sess' already has both titled panes — reusing it (nothing duplicated)"
                return 0
            fi
            die E_COCKPIT_MALFORMED \
                "local session '$sess' exists but does not have panes titled '$SEND_TITLE' and '$STREAM_TITLE'.
  Refusing to guess which pane is which. Rebuild it deliberately:
      $(basename "$0") --rebuild -s ${CONFIG[session]}
  or tear it down:
      $(basename "$0") --teardown -s ${CONFIG[session]}" 1
        fi
    fi

    # Pane 1 — the send pane. `-P -F '#{pane_id}'` hands back a %ID; the index
    # it happens to have right now is never recorded anywhere.
    step "local: new-session $sess (pane '$SEND_TITLE')"
    LOCAL_SEND_PANE="$(run_capture tmux new-session -d -s "$sess" -n cockpit \
        -c "$REPO" -P -F '#{pane_id}')"
    [[ -n "$LOCAL_SEND_PANE" ]] || die E_TMUX "tmux new-session produced no pane id" 1
    run tmux select-pane -t "$LOCAL_SEND_PANE" -T "$SEND_TITLE"
    # Titles only survive if tmux is allowed to keep them (some configs let the
    # shell's escape sequences overwrite pane_title on every prompt).
    #
    # The window is addressed VIA THE PANE ID, not "=$sess". `-t =<session>` is
    # a target-SESSION spelling; `set-option -w` wants a target-WINDOW and
    # answers "no such window: =cockpittest-cockpit" — which, without -e, is a
    # printed error the run happily continues past. A %ID resolves to its own
    # window unambiguously and cannot re-map.
    run tmux set-option -t "$LOCAL_SEND_PANE" -w allow-rename off
    run tmux set-option -t "$LOCAL_SEND_PANE" -w automatic-rename off

    # Pane 2 — the stream pane. tcx-stream.sh is given as the pane's COMMAND
    # rather than typed in: nothing to autocorrect, nothing to quote wrong, and
    # #{pane_start_command} then proves what the pane is running.
    step "local: split-window (pane '$STREAM_TITLE' runs setup/tcx-stream.sh)"
    LOCAL_STREAM_PANE="$(run_capture tmux split-window -h -t "$LOCAL_SEND_PANE" \
        -c "$REPO" -P -F '#{pane_id}' "bash $STREAM")"
    [[ -n "$LOCAL_STREAM_PANE" ]] || die E_TMUX "tmux split-window produced no pane id" 1
    run tmux select-pane -t "$LOCAL_STREAM_PANE" -T "$STREAM_TITLE"

    # Leave the send pane focused and pre-typed, but NOT executed.
    run tmux select-pane -t "$LOCAL_SEND_PANE"
    stage_line "$LOCAL_SEND_PANE" "$(basename "$TCX_CLI") send "
}

# ============================================================================
# The closing block: what exists now, and the two or three things to type next.
# Every command printed here must itself be runnable.
# ============================================================================
report() {
    local sess; sess="$(local_session_name)"
    printf '\n%s── cockpit ──%s\n' "$B" "$X"
    printf '  %sworker%s          %s\n' "$D" "$X" "${CONFIG[worker]:-(none — local only)}"
    printf '  %sremote session%s  %s\n' "$D" "$X" "${CONFIG[session]}"
    printf '  %sremote pane%s     %s\n' "$D" "$X" "${REMOTE_PANE:-(not created this run)}"
    printf '  %sshortcut%s        %s\n' "$D" "$X" "${CONFIG[shortcut]}"
    printf '  %slocal session%s   %s\n' "$D" "$X" "$sess"
    printf '  %spanes%s           %s=%s  %s=%s\n' "$D" "$X" \
        "$SEND_TITLE" "${LOCAL_SEND_PANE:--}" "$STREAM_TITLE" "${LOCAL_STREAM_PANE:--}"
    printf '\n%s  next:%s\n' "$B" "$X"
    printf '    %stmux attach -t %s%s\n' "$C" "$sess" "$X"
    printf '    %s%s send %s%s          %s(from the %s pane)%s\n' \
        "$C" "$(basename "$TCX_CLI")" "'your prompt'" "$X" "$D" "$SEND_TITLE" "$X"
    printf '    %s%s --teardown -s %s%s\n' \
        "$C" "$(basename "$0")" "${CONFIG[session]}" "$X"
} >&2   # the report is for the human: GNU §1, stdout carries only machine data

# ============================================================================
# Main
# ============================================================================
REMOTE_PANE=""
LOCAL_SEND_PANE=""
LOCAL_STREAM_PANE=""
TCX_CLI=""

main() {
    parse_args "$@"
    apply_profile

    # --print-target: the one machine-readable query. stdout carries ONLY the
    # target line (GNU §1); everything else this program says goes to stderr.
    if (( PRINT_TARGET )); then
        [[ -s "$TARGET_FILE" ]] || die E_NO_TARGET \
            "no target saved at $TARGET_FILE — build the remote half first, or run: tcx.sh pick" 66
        cat -- "$TARGET_FILE"
        exit 0
    fi

    (( DO_REMOTE || DO_LOCAL || TEARDOWN )) \
        || die E_USAGE "--no-remote and --no-local together leave nothing to do" 64

    build_relay_flags
    preflight

    # --teardown needs only the session name, and must never dial the relay.
    if (( TEARDOWN )); then
        [[ -n "${CONFIG[session]}" ]] || { collect_inputs; }
        validate_session_name
        teardown_local
        exit 0
    fi

    # --no-remote is genuinely local: no relay read, no worker, and — crucially
    # — no write to the shared target file.
    if (( DO_REMOTE )); then
        collect_inputs
        validate_session_name
        validate_dir
        validate_worker
        remote_half
    else
        [[ -n "${CONFIG[session]}" ]] || collect_inputs
        validate_session_name
        note "--no-remote: skipping the relay entirely (target file left untouched)"
    fi

    if (( DO_LOCAL )); then
        local_half
    else
        note "--no-local: no cockpit built"
    fi

    report
}

main "$@"
