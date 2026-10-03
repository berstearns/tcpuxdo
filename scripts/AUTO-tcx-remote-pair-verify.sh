#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-pair-verify.sh <profile> [workspace] — end-to-end
#          proof that a remote-<profile> i3minator launcher works:
#            1. i3minator start remote-<profile>  (the $mod+Ctrl+x path, minus rofi)
#            2. local remote-<profile> appears with panes tcx-send + tcx-stream
#            3. a unique probe prompt is TYPED into tcx-send (the tcx-compose
#               REPL — the pane the human uses), Enter sends it
#            4. the remote claude's answer is read back IN tcx-stream
#            5. screenshot of the workspace + a receipt file
#
# WHY:     2026-10-02: "it works" was first claimed from a dry-run, then the
#          user saw a black window. Only an observed round trip (prompt out,
#          answer back, on the real screen) counts. This was first done with
#          inline commands; this file is that check as a re-runnable program.
#
# INPUTS:  --fresh      first close this launcher's window + the LOCAL cockpit
#          <profile>    line name in profiles.conf (same as remote-<profile>.yml)
#          [workspace]  i3 workspace number (default: the YAML default)
#          env TCX_VERIFY_TIMEOUT  seconds to wait for the answer (default 90)
#
# OUTPUTS: receipt ${XDG_CACHE_HOME:-~/.cache}/tcpuxdo/pair-verify/<profile>-<stamp>.log
#          screenshot same dir, .png (when maim is installed)
#          stdout: "verify<TAB><profile><TAB>PASS|FAIL<TAB>detail"
#          exit 0 PASS · 1 FAIL · 64 usage/preflight
#
# RE-RUN SAFETY: idempotent launch (cockpit reuses both halves); each run sends
#          ONE new probe prompt to the remote claude — that is its only effect.
# PANE ADDRESSING: panes are resolved by TITLE inside remote-<profile> to a
#          %ID; a duplicate or missing title is a hard FAIL, never a guess.
#===============================================================================
set -uo pipefail

CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
TIMEOUT="${TCX_VERIFY_TIMEOUT:-90}"
FRESH=0; [[ "${1:-}" == "--fresh" ]] && { FRESH=1; shift; }   # close window + local half first
P="${1:-}"; WS="${2:-}"
[[ -n "$P" ]] || { echo "usage: AUTO-tcx-remote-pair-verify.sh <profile> [workspace]" >&2; exit 64; }
for c in i3minator i3-msg tmux grep; do command -v "$c" >/dev/null || { echo "verify: missing $c" >&2; exit 64; }; done

line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${P}:")" || { echo "verify: no profile '$P'" >&2; exit 64; }
IFS=':' read -r _ W S _ <<<"$line"
LS="remote-$P"   # local twin session name (see AUTO-tcx-remote-pair-window.sh)
STAMP="$(date +%Y%m%dT%H%M%S)"
DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/pair-verify"; mkdir -p "$DIR"
LOG="$DIR/$P-$STAMP.log"
log(){ printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }
verdict(){ printf 'verify\t%s\t%s\t%s\n' "$P" "$1" "$2" | tee -a "$LOG"; [[ "$1" == PASS ]]; exit $?; }

log "profile=$P worker=$W session=$S local=$LS ws=${WS:-default} fresh=$FRESH"

# 0 — --fresh: close THIS launcher's window (by its unique class) and the LOCAL
#     cockpit only; the remote claude session is left running (re-used).
if (( FRESH )); then
    i3-msg "[class=\"^i3minator-remote-${P}\$\"] kill" >/dev/null 2>&1
    TCX_COCKPIT_LOCAL_SESSION="$LS" "$(dirname "$(readlink -f "$0")")/AUTO-tcx-cockpit.sh" --teardown -s "$S" >> "$LOG" 2>&1
    sleep 1
    tmux has-session -t "=$LS" 2>/dev/null && verdict FAIL "--fresh: $LS still exists after teardown"
    log "fresh: window closed, $LS torn down"
fi

# 1 — launch through i3minator, the same path as the rofi menu
args=(start "remote-$P"); [[ -n "$WS" ]] && args+=(--workspace "$WS")
i3out="$(i3minator "${args[@]}" 2>&1)"; printf '%s\n' "$i3out" >> "$LOG"
grep -q "swallowed" <<<"$i3out" || verdict FAIL "i3minator did not swallow the window (see $LOG)"

# 2 — local pair exists, panes resolved by title
for _ in $(seq 1 60); do tmux has-session -t "=$LS" 2>/dev/null && break; sleep 2; done
tmux has-session -t "=$LS" 2>/dev/null || verdict FAIL "local session $LS never appeared"
pane_by_title(){
    local ids; ids="$(tmux list-panes -s -t "=$LS:" -F '#{pane_id}'$'\t''#{pane_title}' | awk -F'\t' -v t="$1" '$2==t{print $1}')"
    [[ "$(grep -c . <<<"$ids")" == 1 ]] || return 1
    echo "$ids"
}
SEND="$(pane_by_title tcx-send)"     || verdict FAIL "tcx-send title missing or duplicated in $LS"
STREAM="$(pane_by_title tcx-stream)" || verdict FAIL "tcx-stream title missing or duplicated in $LS"
log "tcx-send=$SEND tcx-stream=$STREAM"

# wait for the window program's trust step: the stream must show the claude input box
for _ in $(seq 1 30); do
    tmux capture-pane -p -t "$STREAM" -J | grep -qE 'for shortcuts|bypass permissions on' && break; sleep 2
done

# 3 — probe typed into tcx-send exactly as a human would: tcx-send runs the
#     tcx-compose REPL (set up by AUTO-tcx-remote-pair-window.sh), so the raw
#     prompt + Enter is the whole send. Wait for the REPL first.
for _ in $(seq 1 20); do
    [[ "$(tmux display -p -t "$SEND" '#{pane_start_command}')" == *AUTO-tcx-compose.sh* ]] && break; sleep 1
done
[[ "$(tmux display -p -t "$SEND" '#{pane_start_command}')" == *AUTO-tcx-compose.sh* ]] \
    || verdict FAIL "tcx-send is not running tcx-compose (no usable prompt pane)"
sleep 2
TOKEN="PAIR-OK-${P}-${STAMP}"
tmux send-keys -t "$SEND" -l "Reply with exactly one line: ${TOKEN}"
sleep 0.3; tmux send-keys -t "$SEND" Enter
log "sent probe $TOKEN"

# 4 — answer in tcx-stream ("● TOKEN" = claude's reply bullet, not the echo of the prompt)
deadline=$(( SECONDS + TIMEOUT ))
until tmux capture-pane -p -t "$STREAM" -J -S -200 | grep -q "● ${TOKEN}"; do
    (( SECONDS > deadline )) && {
        tmux capture-pane -p -t "$STREAM" -J -S -60 >> "$LOG"
        verdict FAIL "no reply '● $TOKEN' in tcx-stream within ${TIMEOUT}s (pane dump in $LOG)"; }
    sleep 3
done
log "reply seen in tcx-stream"

# 4b — the remote agent must not block on tool-permission dialogs (2026-10-02)
tmux capture-pane -p -t "$STREAM" -J | grep -q 'bypass permissions on' \
    || verdict FAIL "remote claude is NOT in bypass-permissions mode — it will block on tool prompts (fix: AUTO-tcx-remote-claude-restart.sh $P)"
log "remote claude is in bypass-permissions mode"

# 5 — evidence
ws_name="$(tmux display -p -t "$SEND" '#{session_name}')"
i3-msg "[class=\"^i3minator-remote-${P}\$\"] focus" >/dev/null 2>&1; sleep 1.5
if command -v maim >/dev/null; then maim "$DIR/$P-$STAMP.png" && log "screenshot $DIR/$P-$STAMP.png"; fi
verdict PASS "round trip ok via $W ($ws_name); receipt $LOG"
