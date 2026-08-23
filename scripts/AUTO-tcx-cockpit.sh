#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-cockpit.sh — the stage-2 cockpit CLI so far: the option
#          surface, the dry-run preview machinery, and a preflight that reads
#          LIVE relay state to validate a worker, rofi prompts (or a named
#          profile) for whatever the CLI did not supply, and the LOCAL half of
#          the cockpit: a tmux session <name>-cockpit with two TITLED panes —
#          "tcx-send" at a prompt, "tcx-stream" running setup/tcx-stream.sh.
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
#          -p, --profile NAME   named preset from the profiles file
#          -n, --dry-run        print every command, run NOTHING
#              --no-color       disable ANSI
#          -h, --help
#
#          Env overrides: TCX_COCKPIT_WORKER, TCX_COCKPIT_SESSION,
#          TCX_COCKPIT_DIR, TCX_COCKPIT_PROFILE, TCX_COCKPIT_PROFILES_FILE,
#          TCX_COCKPIT_ROFI_LINES, TCX_COCKPIT_DEAD_SECS, TCX_COCKPIT_HOST,
#          TCX_COCKPIT_PORT.
#
# OUTPUTS / SIDE EFFECTS:
#          creates a local tmux session <name>-cockpit with two titled panes.
#          One read-only relay RPC (--op state) when a worker is supplied.
#          Nothing is sent to any remote pane; no file is written.
#          exit 0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable
#          · 64 usage error.
#
# USAGE (combinatorial):
#   AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
#       # resolve the three inputs and print the plan
#   AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
#       # the same, in dry-run mode
#   AUTO-tcx-cockpit.sh
#       # rofi asks for worker (from LIVE state), session and dir
#   AUTO-tcx-cockpit.sh -p ferret
#       # the same three inputs, from a saved profile
#   AUTO-tcx-cockpit.sh -w no-such-worker -s ferret -d '~'
#       # INVALID: unknown worker, exit 2, with the live worker list
#   AUTO-tcx-cockpit.sh --nonsense
#       # INVALID: unknown option, exit 64
#
# NOT IN THIS COMMIT, on purpose: the remote half — create-session,
#          create-pane, send-keys, and the shared target file. Until it lands,
#          the stream pane shows "no target set", which is what tcx-stream.sh
#          prints when it has nothing to mirror.
#
# PANE ADDRESSING: never `session:window.index` — indexes re-map on every split.
#          Panes are created with `-P -F '#{pane_id}'`, titled with
#          `select-pane -T`, and re-found by TITLE. A duplicate title is a hard
#          error, never a `head -1` guess (~/.claude/rules/tmux-pane-routing.md).
#
# RE-RUN SAFETY: idempotent. An existing <name>-cockpit carrying both titled
#          panes is REUSED. A malformed one is a NAMED error pointing at
#          --rebuild; it is never silently duplicated or repaired.
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
    [rofi_lines]="${TCX_COCKPIT_ROFI_LINES:-12}"
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
REBUILD=0
TEARDOWN=0

# Local pane titles. Fixed, because the self-check and docs both name them.
SEND_TITLE="tcx-send"
STREAM_TITLE="tcx-stream"

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
            --rebuild)     REBUILD=1; shift ;;
            --teardown)    TEARDOWN=1; shift ;;
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
  -p, --profile NAME    named preset from ${CONFIG[profiles_file]}
  -n, --dry-run         print every command, run nothing
      --rebuild         kill an existing local cockpit and rebuild it
      --teardown        kill the local cockpit and exit
      --no-color        disable ANSI
  -h, --help            this text

Anything not given on the CLI is asked for with rofi. The worker list always
comes from LIVE relay state (tcpuxdo --op state), never a hardcoded list.

Profiles file (${CONFIG[profiles_file]}), one per line:
  # name:worker:session:dir
  ferret:newlaptop:ferret:~/p/ferret

Exit codes:
  0 ok · 1 runtime failure · 2 bad input · 3 relay unreachable · 64 usage

Examples:
  AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'
  AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'
  AUTO-tcx-cockpit.sh -p ferret
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
    # rofi is only load-bearing when something still has to be asked for. It is
    # checked here (named, once) rather than at the prompt, where a missing
    # binary would look like the prompt being cancelled.
    if [[ -z "${CONFIG[worker]}" || -z "${CONFIG[session]}" || -z "${CONFIG[dir]}" ]]; then
        command -v rofi >/dev/null || die E_MISSING_DEP \
            "rofi not on PATH and an input is missing — pass -w/-s/-d explicitly" 1
    fi
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

# ============================================================================
# Input collection — rofi, but only for what is still missing. Kept inline
# (~30 lines) rather than split into AUTO-tcx-cockpit-rofi.sh: a second file
# that is only ever called from one place earns nothing.
# ============================================================================
rofi_pick() {  # $1 prompt  $2.. options ; stdin is closed so a piped caller
               # can never make rofi read the pipe (constraint: </dev/null)
    printf '%s\n' "${@:2}" | rofi -dmenu -i -p "$1" -lines "${CONFIG[rofi_lines]}" </dev/null
}

rofi_ask() {  # $1 prompt  $2 default ; free text
    printf '%s\n' "$2" | rofi -dmenu -i -p "$1" -lines 1 </dev/null
}

collect_inputs() {
    if [[ -z "${CONFIG[worker]}" ]]; then
        require_state
        local -a workers=()
        mapfile -t workers < <(worker_list)
        (( ${#workers[@]} )) || die E_NO_WORKERS \
            "no worker has ever registered with the relay — bring one up with setup/node-up.sh" 2
        CONFIG[worker]="$(rofi_pick "worker" "${workers[@]}")"
        [[ -n "${CONFIG[worker]}" ]] || die E_CANCELLED "no worker chosen" 2
    fi
    if [[ -z "${CONFIG[session]}" ]]; then
        CONFIG[session]="$(rofi_ask "remote session name" "claude")"
        [[ -n "${CONFIG[session]}" ]] || die E_CANCELLED "no session name given" 2
    fi
    if [[ -z "${CONFIG[dir]}" ]]; then
        CONFIG[dir]="$(rofi_ask "remote working dir" "~")"
        [[ -n "${CONFIG[dir]}" ]] || die E_CANCELLED "no working directory given" 2
    fi
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
    printf '  %ssession%s         %s\n' "$D" "$X" "${CONFIG[session]}"
    printf '  %slocal session%s   %s\n' "$D" "$X" "$sess"
    printf '  %spanes%s           %s=%s  %s=%s\n' "$D" "$X" \
        "$SEND_TITLE" "${LOCAL_SEND_PANE:--}" "$STREAM_TITLE" "${LOCAL_STREAM_PANE:--}"
    printf '\n%s  next:%s\n' "$B" "$X"
    printf '    %stmux attach -t %s%s\n' "$C" "$sess" "$X"
    printf '    %s%s send %s%s          %s(from the %s pane)%s\n' \
        "$C" "$(basename "$TCX_CLI")" "'your prompt'" "$X" "$D" "$SEND_TITLE" "$X"
    printf '    %s%s --teardown -s %s%s\n' \
        "$C" "$(basename "$0")" "${CONFIG[session]}" "$X"
}

# ============================================================================
# Main
# ============================================================================
LOCAL_SEND_PANE=""
LOCAL_STREAM_PANE=""
TCX_CLI=""

main() {
    parse_args "$@"
    apply_profile
    build_relay_flags
    preflight

    # The local cockpit needs only a session name. The relay is not consulted
    # for it — and must not be, or a fleet whose workers are all silent would
    # block a cockpit that does not depend on them.
    if [[ -z "${CONFIG[session]}" ]]; then
        CONFIG[session]="$(rofi_ask "session name" "claude")"
        [[ -n "${CONFIG[session]}" ]] || die E_CANCELLED "no session name given" 2
    fi
    validate_session_name

    # A worker is not needed to build the cockpit, but if one was supplied it
    # is still validated. A rung must ADD a capability, never quietly drop the
    # one the rung below it added: skipping this here would make -w silently
    # accept a name the previous commit correctly rejected.
    [[ -n "${CONFIG[worker]}" ]] && validate_worker

    if (( TEARDOWN )); then
        teardown_local
        exit 0
    fi

    local_half
    report
}

main "$@"
