#!/usr/bin/env bash
#===============================================================================
# WHAT:    Self-check harness for scripts/AUTO-tcx-cockpit.sh. Runs the seven
#          acceptance checks the cockpit was specified against, plus a NEGATIVE
#          mode in which every load-bearing assertion is deliberately broken and
#          observed RED.
#
# WHY:     Same reason AUTO-tcx-cli-selfcheck.sh exists: an ergonomic wrapper
#          fails silently and plausibly — a dropped flag, a dry run that was
#          live, a preview of the command that PREPARES instead of the one that
#          ACTS, an assertion incapable of failing. The defence is to make each
#          check capable of failing and watch it fail once
#          (daily-claude-rules/2026-08-09/ergonomic-cli-entrypoints, rules 01,
#          05, 06, 08, 10).
#
#          The relay override matters as much as the cases. ./tcpuxdo sources
#          .env with `set -o allexport`, so .env OVERRIDES the caller's
#          environment: a "dead relay" test written as `TCPUX_PORT=1 …` talks to
#          the PRODUCTION relay and passes without testing anything. This
#          harness aims the cockpit with TCX_COCKPIT_HOST/PORT, which the
#          cockpit forwards as client.py --host/--port, where it actually wins.
#
# INPUTS:  $1 mode (default: all)
#            help       --help exits 0 and shows every documented flag
#            dry        --dry-run prints the real tcpuxdo argv and creates NOTHING
#            badworker  an unknown worker is a named error, exit 2, no session
#            deadrelay  an unreachable relay is a named error, not a traceback
#            local      --no-remote builds two TITLED panes, stream runs tcx-stream.sh
#            idem       --no-remote twice: still exactly one session, two panes
#            teardown   --teardown removes the session and leaves nothing behind
#            tty        --tty collects piped stdin answers without rofi
#            gnu        stdout-is-data + documented exit codes (GNU §1/§2)
#            completion bash+zsh completion scripts, worker-value completion
#            negative   every assertion above, deliberately broken, must go RED
#            all        every mode above (negative included)
#
#          Env: TCX_COCKPIT_SELFCHECK_SESSION (default `cockpitselfcheck`)
#          names the throwaway tmux session, so the harness can never touch a
#          real cockpit.
#
# OUTPUTS / SIDE EFFECTS:
#          stdout: one PASS/FAIL line per case + a final tally.
#          creates and then DESTROYS one local tmux session (the selfcheck one).
#          Sends NOTHING to any remote pane: every remote path is either a
#          dry run or an expected rejection.
#          Never writes the shared target file: the only mode that would
#          (a live remote run) is not exercised.
#          exit 0 all green · 1 one or more FAIL · 64 bad mode.
#
# USAGE (combinatorial):
#   ./scripts/AUTO-tcx-cockpit-selfcheck.sh
#       # the gate: all eight modes, one tally
#   ./scripts/AUTO-tcx-cockpit-selfcheck.sh local
#       # just the cockpit-building check — the fast loop while editing local_half
#   ./scripts/AUTO-tcx-cockpit-selfcheck.sh negative
#       # prove the assertions can fail; run after ANY change to the others
#   ./scripts/AUTO-tcx-cockpit-selfcheck.sh dry teardown
#       # INVALID: one mode per run; exits 64
#
# RE-RUN SAFETY: idempotent. It tears its own session down on the way in and on
#          the way out, and touches nothing else.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COCKPIT="$HERE/AUTO-tcx-cockpit.sh"
SESS="${TCX_COCKPIT_SELFCHECK_SESSION:-cockpitselfcheck}"
LOCAL_SESS="$SESS-cockpit"

G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; X=$'\033[0m'
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$X" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$X" "$1"
        [[ -n "${2:-}" ]] && printf '       %sgot:%s %s\n' "$D" "$X" "${2//$'\n'/ | }"; return 0; }
head_() { printf '\n%s== %s ==%s\n' "$B" "$1" "$X"; }

# Every invocation of the program under test goes through here: colour off so
# assertions match plain text, and the throwaway session name always supplied.
cockpit() { env NO_COLOR=1 bash "$COCKPIT" "$@"; }

session_count() { tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cx "$LOCAL_SESS" || true; }
pane_count()    { tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_id}' 2>/dev/null | grep -c . || true; }
pane_titles()   { tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_title}' 2>/dev/null; }
pane_starts()   { tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_start_command}' 2>/dev/null; }

wipe() { tmux kill-session -t "=$LOCAL_SESS" 2>/dev/null; return 0; }

# A LIVE worker name, taken from the registry, so the badworker case can prove
# it rejects the bad one specifically rather than rejecting everything.
live_worker() {
    "$ROOT/tcpuxdo" --op state 2>/dev/null | jq -r '.state | keys[0] // empty' 2>/dev/null
}

#------------------------------------------------------------------------------
# 1. --help exits 0 and shows EVERY flag. Not "a flag" — every one, by name,
#    because a vanished flag is the failure this check exists for.
#------------------------------------------------------------------------------
mode_help() {
    head_ "help — --help exits 0 and documents every flag"
    local out rc
    out="$(cockpit --help 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ok "--help exits 0" || bad "--help exited $rc" "$out"
    local f missing=""
    for f in -w --worker -s --session -d --dir -p --profile -n --dry-run \
             --no-remote --no-local --tty --print-target -h --help --version; do
        grep -qF -- "$f" <<<"$out" || missing="$missing $f"
    done
    [[ -z "$missing" ]] && ok "--help names every required flag" \
                        || bad "--help is missing:$missing" "$out"
}

#------------------------------------------------------------------------------
# 2. --dry-run prints the exact tcpuxdo argv and creates NOTHING.
#    "Creates nothing" is asserted against tmux itself, not against the absence
#    of an error message.
#------------------------------------------------------------------------------
mode_dry() {
    head_ "dry — --dry-run previews the real argv and creates nothing"
    wipe
    local w out rc before after
    w="$(live_worker)"
    if [[ -z "$w" ]]; then
        bad "dry — no worker in the registry, cannot build a realistic dry run" ""
        return
    fi
    before="$(session_count)"
    # TCX_COCKPIT_DEAD_SECS is raised on purpose: the freshness gate is a
    # DIFFERENT check (badworker/deadrelay cover the refusals). Leaving it at
    # the default would make this case assert the gate, not the dry run.
    out="$(env TCX_COCKPIT_DEAD_SECS=99999999 NO_COLOR=1 \
           bash "$COCKPIT" -n -w "$w" -s "$SESS" -d '~/p/tcpuxdo' 2>&1)"; rc=$?
    after="$(session_count)"

    [[ "$rc" == 0 ]] && ok "dry run exits 0" || bad "dry run exited $rc" "$out"

    # The tcpuxdo argv must be previewed VERBATIM — the three ops, in order.
    local want missing=""
    for want in "--op create-session --worker $w --session $SESS" \
                "--op shortcut-set --name claude-main" \
                "-w $w -p $SESS:0:0" \
                "--no-cascade"; do
        grep -qF -- "$want" <<<"$out" || missing="$missing [$want]"
    done
    [[ -z "$missing" ]] && ok "dry run previews the exact tcpuxdo argv (3 ops, in order)" \
                        || bad "dry-run preview lacks:$missing" "$out"

    # PATH-safety: the remote launch must go through a LOGIN shell, so claude
    # resolves even when the fresh pane never sourced the rc that set PATH.
    grep -qF -- "bash -lc" <<<"$out" \
        && ok "remote launch is PATH-safe (wrapped in a login shell: bash -lc)" \
        || bad "remote launch is a bare command — command-not-found on a fresh pane" "$out"

    # And the tmux side, including the pane-title calls.
    for want in "tmux new-session" "tmux split-window" "select-pane" "tcx-stream" "tcx-send"; do
        grep -qF -- "$want" <<<"$out" || missing="$missing [$want]"
    done
    [[ -z "$missing" ]] && ok "dry run previews the tmux argv including both pane titles" \
                        || bad "dry-run preview lacks:$missing" "$out"

    # THE assertion: nothing was created. Compared against tmux, not the output.
    if [[ "$before" == "$after" && "$after" == "0" ]]; then
        ok "dry run created NO tmux session (before=$before after=$after)"
    else
        bad "dry run CREATED a session" "before=$before after=$after"
    fi
}

#------------------------------------------------------------------------------
# 3. Bad worker name -> named error, exit non-zero, no session created.
#------------------------------------------------------------------------------
mode_badworker() {
    head_ "badworker — an unknown worker is a named error, and builds nothing"
    wipe
    local out rc
    out="$(cockpit -w no-such-worker-xyz -s "$SESS" -d '~' 2>&1)"; rc=$?
    if [[ "$rc" != 0 ]] && grep -q 'E_UNKNOWN_WORKER' <<<"$out"; then
        ok "unknown worker -> E_UNKNOWN_WORKER, exit $rc"
    else
        bad "unknown worker should be a NAMED error with a non-zero exit" "rc=$rc $out"
    fi
    # The error must list what DOES exist — an error that does not say what to
    # type instead is half an error.
    grep -q 'known workers:' <<<"$out" \
        && ok "the error lists the workers that do exist" \
        || bad "the error does not list the known workers" "$out"
    [[ "$(session_count)" == "0" ]] \
        && ok "no local session was created on the failing path" \
        || bad "a session was created despite the failure" "count=$(session_count)"
}

#------------------------------------------------------------------------------
# 4. Relay unreachable -> named error, not a python traceback.
#------------------------------------------------------------------------------
mode_deadrelay() {
    head_ "deadrelay — an unreachable relay is a named error, not a stack trace"
    wipe
    local out rc
    # Port 1 on localhost: closed, and refuses fast. TCX_COCKPIT_* (not
    # TCPUX_*) because .env would otherwise put the real relay back.
    out="$(env TCX_COCKPIT_HOST=127.0.0.1 TCX_COCKPIT_PORT=1 NO_COLOR=1 \
           bash "$COCKPIT" -w anything -s "$SESS" -d '~' 2>&1)"; rc=$?
    if [[ "$rc" == 3 ]] && grep -q 'E_RELAY_UNREACHABLE' <<<"$out"; then
        ok "dead relay -> E_RELAY_UNREACHABLE, exit 3"
    else
        bad "dead relay should exit 3 with E_RELAY_UNREACHABLE" "rc=$rc $out"
    fi
    grep -qE 'Traceback|ConnectionRefusedError|File "' <<<"$out" \
        && bad "a python traceback leaked to the user" "$out" \
        || ok "no python traceback leaked"
    grep -q 'CANNOT-TELL' <<<"$out" \
        && ok "the error says CANNOT-TELL, not 'no workers'" \
        || bad "the error conflates unreachable with empty" "$out"
    [[ "$(session_count)" == "0" ]] \
        && ok "no local session was created on the failing path" \
        || bad "a session was created despite the failure" "count=$(session_count)"
}

#------------------------------------------------------------------------------
# 5. --no-remote builds a session with TWO TITLED panes, stream runs tcx-stream.sh
#------------------------------------------------------------------------------
mode_local() {
    head_ "local — --no-remote builds two titled panes, stream runs tcx-stream.sh"
    wipe
    local out rc
    out="$(cockpit --no-remote -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ok "--no-remote exits 0" || bad "--no-remote exited $rc" "$out"

    [[ "$(session_count)" == "1" ]] \
        && ok "exactly one session named $LOCAL_SESS exists" \
        || bad "expected 1 session named $LOCAL_SESS" "count=$(session_count)"

    [[ "$(pane_count)" == "2" ]] \
        && ok "the session has exactly two panes" \
        || bad "expected two panes" "count=$(pane_count) titles=$(pane_titles | tr '\n' ',')"

    local titles; titles="$(pane_titles | sort | tr '\n' ',')"
    [[ "$titles" == "tcx-send,tcx-stream," ]] \
        && ok "both panes are titled: $titles" \
        || bad "pane titles wrong (want tcx-send,tcx-stream,)" "$titles"

    # WHICH pane runs the streamer, proven from pane_start_command — the pane's
    # own record of what it was launched with, not a guess from its title.
    local starts; starts="$(pane_starts | tr '\n' '|')"
    grep -q 'tcx-stream.sh' <<<"$starts" \
        && ok "a pane was started with tcx-stream.sh: $starts" \
        || bad "no pane was started with tcx-stream.sh" "$starts"

    # …and that it is the pane TITLED tcx-stream, not merely some pane.
    local st_id st_cmd
    st_id="$(tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_id}	#{pane_title}' \
             | awk -F'\t' '$2=="tcx-stream"{print $1}')"
    st_cmd="$(tmux display-message -p -t "$st_id" '#{pane_start_command}' 2>/dev/null)"
    grep -q 'tcx-stream.sh' <<<"$st_cmd" \
        && ok "the pane TITLED tcx-stream is the one running it ($st_id)" \
        || bad "the tcx-stream-titled pane runs something else" "$st_id -> $st_cmd"

    # --no-remote must not touch the shared target file. The remote half is the
    # only writer; a local-only run that redirected someone's in-flight send
    # would be the 2026-07-21 incident again.
    grep -q 'target file left untouched' <<<"$out" \
        && ok "--no-remote states it left the shared target file alone" \
        || bad "--no-remote did not state it skipped the target write" "$out"
}

#------------------------------------------------------------------------------
# 6. Idempotency: run --no-remote twice, still exactly one session, two panes.
#------------------------------------------------------------------------------
mode_idem() {
    head_ "idem — --no-remote twice leaves one session with two panes"
    wipe
    local out1 out2 rc2
    out1="$(cockpit --no-remote -s "$SESS" 2>&1)"
    out2="$(cockpit --no-remote -s "$SESS" 2>&1)"; rc2=$?

    [[ "$rc2" == 0 ]] && ok "the second run exits 0" || bad "second run exited $rc2" "$out2"
    grep -q 'reusing it' <<<"$out2" \
        && ok "the second run says it REUSED the session" \
        || bad "the second run did not announce a reuse" "$out2"
    [[ "$(session_count)" == "1" ]] \
        && ok "still exactly one session after two runs" \
        || bad "session count is not 1 after two runs" "count=$(session_count)"
    [[ "$(pane_count)" == "2" ]] \
        && ok "still exactly two panes after two runs" \
        || bad "pane count is not 2 after two runs" "count=$(pane_count)"
}

#------------------------------------------------------------------------------
# 7. Teardown works and leaves nothing behind.
#------------------------------------------------------------------------------
mode_teardown() {
    head_ "teardown — --teardown removes the session and leaves nothing"
    wipe
    cockpit --no-remote -s "$SESS" >/dev/null 2>&1
    [[ "$(session_count)" == "1" ]] || { bad "could not set up a session to tear down" ""; return; }
    local out rc
    out="$(cockpit --teardown -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ok "--teardown exits 0" || bad "--teardown exited $rc" "$out"
    [[ "$(session_count)" == "0" ]] \
        && ok "the session is gone" \
        || bad "the session survived --teardown" "count=$(session_count)"
    # Nothing behind: no orphan pane anywhere in the tmux server carrying our
    # titles, and no stray tcx-stream.sh process started by this session.
    local orphan
    orphan="$(tmux list-panes -a -F '#{session_name}	#{pane_title}' 2>/dev/null \
              | awk -F'\t' -v s="$LOCAL_SESS" '$1==s || $2=="tcx-send" && $1==s' | grep -c . || true)"
    [[ "$orphan" == "0" ]] && ok "no orphan pane left behind" \
                           || bad "orphan panes remain" "$orphan"
    # A second teardown must be harmless, not an error.
    out="$(cockpit --teardown -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ok "a second --teardown is harmless (exit 0)" \
                     || bad "a second --teardown exited $rc" "$out"
}

#------------------------------------------------------------------------------
# 8. tty mode: --tty with the answers piped on stdin collects WITHOUT rofi.
#    DISPLAY is scrubbed so the rofi path is provably impossible; --dry-run so
#    nothing is created; the piped session name must surface in the preview.
#------------------------------------------------------------------------------
mode_tty() {
    head_ "tty — --tty collects piped inputs without rofi, creates nothing"
    wipe
    local out rc
    out="$(printf 'ttyanswer\n' \
           | env -u DISPLAY NO_COLOR=1 bash "$COCKPIT" --tty --no-remote -n -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && ok "--tty piped run exits 0 (session given as flag)" \
                     || bad "--tty piped run exited $rc" "$out"
    # Now leave -s OUT: the session name must be COLLECTED from the pipe.
    out="$(printf '%s\n' "$SESS" \
           | env -u DISPLAY NO_COLOR=1 bash "$COCKPIT" --tty --no-remote -n 2>&1)"; rc=$?
    if [[ "$rc" == 0 ]] && grep -qF -- "$SESS-cockpit" <<<"$out"; then
        ok "--tty collected the session name from stdin (no rofi, DISPLAY unset)"
    else
        bad "--tty did not collect the piped session name" "rc=$rc $out"
    fi
    [[ "$(session_count)" == "0" ]] \
        && ok "the tty dry run created nothing" \
        || bad "the tty dry run created a session" "count=$(session_count)"
    # Closed stdin (no answer possible) must be a NAMED refusal, never a hang.
    # Preflight catches it before any prompt: E_MISSING_DEP naming the flags.
    out="$(timeout 10 env -u DISPLAY NO_COLOR=1 \
           bash "$COCKPIT" --tty --no-remote -n </dev/null 2>&1)"; rc=$?
    if [[ "$rc" != 0 && "$rc" != 124 ]] && grep -qE 'E_MISSING_DEP|E_CANCELLED' <<<"$out"; then
        ok "closed stdin -> named refusal before any prompt (rc=$rc, no hang)"
    else
        bad "closed stdin should refuse with a named error, not hang" "rc=$rc $out"
    fi
}

#------------------------------------------------------------------------------
# 9+10. GNU contract: stdout is data only; exit codes documented and distinct.
#------------------------------------------------------------------------------
mode_gnu() {
    head_ "gnu — stdout carries only machine data; exit codes are documented"
    wipe
    local out err rc
    # §1: --print-target piped — stdout must be EXACTLY the target line.
    out="$(cockpit --print-target 2>/dev/null | cat)"; rc=$?
    if [[ "$rc" == 0 ]] && grep -qE $'^[^\t]+\t[^\t]+$' <<<"$out" \
       && [[ "$(grep -c . <<<"$out")" == 1 ]]; then
        ok "--print-target piped: stdout is exactly one worker<TAB>pane line"
    elif [[ "$rc" == 66 ]]; then
        ok "--print-target with no saved target: exit 66, stdout empty (no lie)"
    else
        bad "--print-target stdout is not clean single-line data" "rc=$rc [$out]"
    fi
    # §1: a build run must put NOTHING on stdout (report goes to stderr).
    out="$(cockpit --no-remote -s "$SESS" 2>/dev/null)"; rc=$?
    [[ -z "$out" ]] \
        && ok "--no-remote build: stdout is empty, the report went to stderr" \
        || bad "a log/report line leaked to stdout (GNU §1)" "[$out]"
    wipe
    # §2: --help documents the exit codes…
    out="$(cockpit --help 2>&1)"
    grep -q 'Exit codes:' <<<"$out" && grep -q '64' <<<"$out" \
        && ok "--help lists the exit codes" \
        || bad "--help does not document exit codes" "$out"
    # …and an induced usage error really exits 64.
    err="$(cockpit --no-such-flag 2>&1)"; rc=$?
    [[ "$rc" == 64 ]] && grep -q 'E_USAGE' <<<"$err" \
        && ok "unknown flag -> E_USAGE, exit 64" \
        || bad "unknown flag should exit 64 with E_USAGE" "rc=$rc $err"
}

#------------------------------------------------------------------------------
# 11. completion bash|zsh print non-empty scripts with worker-VALUE completion.
#------------------------------------------------------------------------------
mode_completion() {
    head_ "completion — bash+zsh scripts exist, parse, and complete worker values"
    local sh out rc
    for sh in bash zsh; do
        out="$(cockpit completion "$sh" 2>&1)"; rc=$?
        [[ "$rc" == 0 && -n "$out" ]] \
            && ok "completion $sh exits 0 and is non-empty" \
            || { bad "completion $sh failed" "rc=$rc"; continue; }
        grep -q -- '--op state' <<<"$out" && grep -q -- '--worker' <<<"$out" \
            && ok "completion $sh completes worker VALUES from live state" \
            || bad "completion $sh lacks worker-value completion" "$out"
        if command -v "$sh" >/dev/null; then
            "$sh" -n <(printf '%s\n' "$out") 2>/dev/null \
                && ok "completion $sh parses as valid $sh" \
                || bad "completion $sh does not parse" ""
        fi
    done
    # an unknown shell is a usage error, not silence
    out="$(cockpit completion fish 2>&1)"; rc=$?
    [[ "$rc" == 64 ]] && ok "completion fish -> usage error 64" \
                      || bad "unknown completion shell should exit 64" "rc=$rc $out"
}

#------------------------------------------------------------------------------
# NEGATIVE — every load-bearing assertion above, deliberately broken. An
# assertion that cannot go red is decoration; this mode watches each one fail.
# It reports PASS when the underlying check correctly reports a problem.
#------------------------------------------------------------------------------
mode_negative() {
    head_ "negative — each load-bearing assertion, deliberately broken"
    wipe

    # (a) the "creates nothing" assertion must notice a session that DOES exist
    tmux new-session -d -s "$LOCAL_SESS" 2>/dev/null
    [[ "$(session_count)" == "1" ]] \
        && ok "session_count() sees a session that exists (it can go red)" \
        || bad "session_count() cannot see an existing session — the dry-run assertion is vacuous" ""
    wipe
    [[ "$(session_count)" == "0" ]] \
        && ok "session_count() sees the absence too" \
        || bad "session_count() reports a session that is gone" ""

    # (b) the pane-count assertion must notice a THIRD pane
    cockpit --no-remote -s "$SESS" >/dev/null 2>&1
    local send_id
    send_id="$(tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_id}	#{pane_title}' \
               | awk -F'\t' '$2=="tcx-send"{print $1}')"
    tmux split-window -d -t "$send_id" 2>/dev/null
    [[ "$(pane_count)" == "3" ]] \
        && ok "pane_count() notices a third pane (the idempotency check can go red)" \
        || bad "pane_count() did not notice a third pane" "count=$(pane_count)"

    # (c) the TITLE assertion must notice an untitled pane
    local titles; titles="$(pane_titles | sort | tr '\n' ',')"
    [[ "$titles" != "tcx-send,tcx-stream," ]] \
        && ok "the title assertion notices the extra untitled pane: $titles" \
        || bad "the title assertion cannot distinguish 2 panes from 3" "$titles"

    # (d) A HUMAN-ADDED third pane is NOT malformed. Both managed panes are
    #     still there and still titled, so the run reuses the session and adds
    #     nothing. This is asserted rather than assumed: the first draft of the
    #     guard was written as "exactly two panes", which would have refused to
    #     run again the moment the user split a scratch pane of their own.
    local out rc
    out="$(cockpit --no-remote -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 0 ]] && grep -q 'reusing it' <<<"$out" \
        && ok "a human-added third pane still REUSES the session (exit 0, nothing duplicated)" \
        || bad "an extra pane should not stop a reuse" "rc=$rc $out"
    [[ "$(pane_count)" == "3" ]] \
        && ok "the reuse added no pane (still 3, not 4)" \
        || bad "the reuse changed the pane count" "count=$(pane_count)"

    # (e) THE malformed case the guard actually exists for: a session with the
    #     cockpit's NAME that is not a cockpit at all (no titled panes). It must
    #     be a named error naming --rebuild, never a silent reuse and never a
    #     second session.
    wipe
    tmux new-session -d -s "$LOCAL_SESS" 2>/dev/null
    out="$(cockpit --no-remote -s "$SESS" 2>&1)"; rc=$?
    if [[ "$rc" != 0 ]] && grep -q 'E_COCKPIT_MALFORMED' <<<"$out"; then
        ok "a same-named NON-cockpit session -> E_COCKPIT_MALFORMED, exit $rc"
    else
        bad "a same-named non-cockpit session should be a named error" "rc=$rc $out"
    fi
    grep -q -- '--rebuild' <<<"$out" \
        && ok "the malformed error names --rebuild as the fix" \
        || bad "the malformed error does not say how to fix it" "$out"
    [[ "$(session_count)" == "1" ]] \
        && ok "the refusal created no second session" \
        || bad "the refusal duplicated the session" "count=$(session_count)"

    # (f) --rebuild really does rebuild it into the two-pane cockpit
    cockpit --rebuild --no-remote -s "$SESS" >/dev/null 2>&1
    [[ "$(pane_count)" == "2" ]] \
        && ok "--rebuild turns it into exactly two panes" \
        || bad "--rebuild did not restore two panes" "count=$(pane_count)"
    [[ "$(pane_titles | sort | tr '\n' ',')" == "tcx-send,tcx-stream," ]] \
        && ok "--rebuild restores both titles" \
        || bad "--rebuild left the titles wrong" "$(pane_titles | tr '\n' ',')"
    send_id="$(tmux list-panes -s -t "=$LOCAL_SESS" -F '#{pane_id}	#{pane_title}' \
               | awk -F'\t' '$2=="tcx-send"{print $1}')"

    # (g) the tcx-stream assertion must notice a pane that is NOT running it
    local fake
    fake="$(tmux display-message -p -t "$send_id" '#{pane_start_command}' 2>/dev/null)"
    [[ -z "$fake" ]] \
        && ok "the tcx-stream assertion can go red: the send pane has no start command" \
        || bad "the send pane also carries a start command — the assertion cannot distinguish the two" "$fake"

    # (h) --no-remote --no-local is a usage error, not a silent no-op
    out="$(cockpit --no-remote --no-local -s "$SESS" 2>&1)"; rc=$?
    [[ "$rc" == 64 ]] && grep -q 'E_USAGE' <<<"$out" \
        && ok "--no-remote --no-local -> E_USAGE, exit 64" \
        || bad "the empty-work combination should be a usage error" "rc=$rc $out"

    # (i) the remote dir is a BOUNDED primitive. `-d` is interpolated into
    #     `cd <dir> && claude` on the worker, so an unbounded -d is arbitrary
    #     remote code wearing a path's name. Both halves are asserted: the
    #     shell-metacharacter forms are refused, and an ordinary path is not.
    local d
    for d in '~ && curl x | sh' '~; rm -rf /' '$(id)' '`id`' '~/p/a b'; do
        out="$(cockpit -w x -s "$SESS" -d "$d" 2>&1)"; rc=$?
        if [[ "$rc" == 2 ]] && grep -q 'E_BAD_DIR' <<<"$out"; then
            ok "remote dir refused: $d"
        else
            bad "remote dir NOT refused: $d" "rc=$rc $out"
        fi
    done
    for d in '~' '~/p/ferret' '/home/b/p/tcpuxdo' './x' '~/a-b_c.d+e'; do
        out="$(cockpit -w no-such-worker-xyz -s "$SESS" -d "$d" 2>&1)"
        grep -q 'E_BAD_DIR' <<<"$out" \
            && bad "ordinary path wrongly refused: $d" "$out" \
            || ok "ordinary path accepted: $d"
    done

    # (j) a session name outside the IDENT grammar is refused BEFORE the relay
    out="$(cockpit --no-remote -s 'bad name!' 2>&1)"; rc=$?
    [[ "$rc" == 2 ]] && grep -q 'E_BAD_SESSION' <<<"$out" \
        && ok "a non-IDENT session name -> E_BAD_SESSION, exit 2" \
        || bad "a non-IDENT session name should be refused with a named error" "rc=$rc $out"

    wipe
}

#------------------------------------------------------------------------------
MODE="${1:-all}"
[[ $# -le 1 ]] || { echo "one mode per run (got: $*)" >&2; exit 64; }

case "$MODE" in
    help|dry|badworker|deadrelay|local|idem|teardown|tty|gnu|completion|negative) "mode_$MODE" ;;
    all) mode_help; mode_dry; mode_badworker; mode_deadrelay
         mode_local; mode_idem; mode_teardown; mode_tty; mode_gnu
         mode_completion; mode_negative ;;
    *) echo "usage: $(basename "$0") [help|dry|badworker|deadrelay|local|idem|teardown|tty|gnu|completion|negative|all]" >&2
       exit 64 ;;
esac

wipe   # never leave the throwaway session behind, whatever the mode did

printf '\n%s%d PASS%s  %s%d FAIL%s   %s(mode: %s)%s\n' \
    "$G" "$PASS" "$X" "$([[ $FAIL -gt 0 ]] && echo "$R" || echo "$D")" "$FAIL" "$X" \
    "$D" "$MODE" "$X"
exit $(( FAIL > 0 ))
