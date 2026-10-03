#!/usr/bin/env bash
# tcx-stream.sh — smooth auto-refreshing view of the fixed tcpuxdo target pane.
# Run in a dedicated tmux pane titled "tcx-stream" (the cockpit does this).
#
# WHAT: mirrors the remote Claude pane like a monitor, not like `watch`:
#   - alternate screen, cursor hidden, NEVER `clear` — repaint in place
#     (cursor-home + erase-to-eol per line + erase-below), so an unchanged
#     frame produces ZERO visual change and a changed frame swaps flicker-free;
#   - repaints ONLY when the captured content (or the pane size) changed —
#     detected by hash compare (double buffer);
#   - polls adaptively: 1s while things change, backs off to 5s when idle,
#     snaps back to 1s on the next change;
#   - on relay/wifi errors it KEEPS the last good frame and shows a one-line
#     dim staleness banner ("FROZEN 12s — <relay's own words>") instead of
#     wiping the screen with an error;
#   - captures exactly pane-height lines and truncates to pane width, so the
#     frame can never wrap/scroll and cause jitter.
#
# WHY: the old loop (`clear` + full re-capture every 3s, 20s read wait) blanked
# the pane on every poll and froze on every wifi flap — unusable as a live view.
# This is stage 1 of .llm/todos.md P1: smooth WITHOUT touching the protocol
# core. Stage 2 (true keystroke/byte mirror) needs a protocol extension — see
# docs/remote-pane-mirror/.
#
# INPUTS (env):
#   TCX_STREAM_POLL_MIN  fastest poll seconds (default: 1)
#   TCX_STREAM_POLL_MAX  idle backoff ceiling seconds (default: 5)
#   TCX_STREAM_LINES     force a capture line count (default: pane height - 1)
#   TCX_READ_WAIT        max seconds one capture may block (default: 6)
#   TCX_GROUP            cockpit twin namespace — passed through to tcx.sh
#   TCX_STREAM_POLL      legacy override: seconds, maps to POLL_MIN (kept so
#                        old launchers keep working)
# OUTPUTS: the mirrored frame on the terminal; nothing on stdout worth piping.
# RE-RUN: read-only against the relay (tcx.sh read); safe to kill/restart.
#
# USAGE:
#   setup/tcx-stream.sh                      # follow the shared target file
#   setup/tcx-stream.sh -t wsl-/ww3:0:0      # PIN one pane; ignores the target
#                                            # file, so N streams need no groups
#   TCX_GROUP=20260825 setup/tcx-stream.sh   # follow THAT twin's target
#   setup/tcx-stream.sh -i 20                # SNAPSHOT mode: one frame every
#                                            # 20s, no adaptive backoff — for a
#                                            # flapping uplink where 1s polling
#                                            # just spams FROZEN banners
#   TCX_STREAM_INTERVAL=20 …                 # same, as env (flag wins)
#   TCX_STREAM_RETRIES=3 …                   # capture retries per tick (def 2;
#                                            # reads are idempotent, safe)

set -uo pipefail   # NOT -e — exit codes are handled, a flap must not kill the pane

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/.."
TCX="$HERE/tcx.sh"

INTERVAL="${TCX_STREAM_INTERVAL:-}"
# PIN — stream ONE named pane and ignore the target file entirely.
#
# Without this a stream can only ever follow the shared/grouped target, so two
# streams on one machine need two TCX_GROUPs, two `use` calls and two exports
# before either shows anything. Pinning makes "watch that pane" a property of
# the process, which is what a second stream pane actually is.
PIN="${TCX_STREAM_TARGET:-}"
while [ $# -gt 0 ]; do case "$1" in
  -i|--interval) INTERVAL="${2:?-i needs seconds}"; shift 2 ;;
  -t|--target)   PIN="${2:?-t needs <worker>/<session:window:pane>}"; shift 2 ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) echo "tcx-stream: unknown arg '$1' (try -h)" >&2; exit 64 ;;
esac; done
if [[ -n "$INTERVAL" ]]; then
  [[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 ]] || { echo "tcx-stream: -i needs a positive integer, got '$INTERVAL'" >&2; exit 64; }
  POLL_MIN="$INTERVAL"; POLL_MAX="$INTERVAL"      # fixed cadence: a snapshot every N s
else
  POLL_MIN="${TCX_STREAM_POLL_MIN:-${TCX_STREAM_POLL:-1}}"
  POLL_MAX="${TCX_STREAM_POLL_MAX:-5}"
fi
(( POLL_MAX < POLL_MIN )) && POLL_MAX="$POLL_MIN"
RETRIES="${TCX_STREAM_RETRIES:-2}"           # extra capture attempts per tick
export TCX_READ_WAIT="${TCX_READ_WAIT:-6}"   # short: a stuck capture only delays, never blanks

# TCX_GROUP namespaces the target (one file per cockpit twin): a stream pane
# launched with TCX_GROUP=<session> follows ITS twin's pane forever, immune to
# other twins retargeting the shared file. Unset = the shared file, as before.
TARGET_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo${TCX_GROUP:+/$TCX_GROUP}/target"

PIN_W=""; PIN_P=""
if [[ -n "$PIN" ]]; then
  # "worker/session:window:pane" — the worker is everything before the FIRST
  # slash, so a pane id keeps its colons and a worker name may contain none.
  PIN_W="${PIN%%/*}"; PIN_P="${PIN#*/}"
  [[ -n "$PIN_W" && -n "$PIN_P" && "$PIN_W" != "$PIN_P" ]] || {
    echo "tcx-stream: -t wants <worker>/<session:window:pane>, got '$PIN'" >&2; exit 64; }
fi

TCPUXDO_BIN="$HERE/tcpuxdo"

# ONE capture entrypoint, so the pinned and the following mode cannot drift into
# different retry/timeout behaviour. $1 = line count; frame on stdout.
capture_frame() {
  if [[ -n "$PIN_W" ]]; then
    "$TCPUXDO_BIN" read -w "$PIN_W" -p "$PIN_P" --lines "$1" --wait "${TCX_READ_WAIT:-6}"
  else
    "$TCX" read "$1"
  fi
}

# ── terminal setup: alternate screen, hidden cursor, restore on ANY exit ──
TTY=0; [[ -t 1 ]] && TTY=1
ERRF="$(mktemp)"
cleanup() {
  rm -f "$ERRF"
  if (( TTY )); then tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if (( TTY )); then
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
fi
RESIZED=1
trap 'RESIZED=1' WINCH 2>/dev/null || true

# paint STATUS + FRAME in place: home, line-wise overwrite with erase-to-eol,
# erase everything below. One printf = one atomic-looking swap, no flicker.
paint() {  # $1 status line  $2 frame  $3 terminal cols
  local buf line
  buf=$'\033[H'"$1"$'\033[K\n'
  while IFS= read -r line; do
    buf+="$line"$'\033[K\n'
  done <<< "$2"
  buf+=$'\033[0J'
  printf '%s' "$buf"
}

paint_status_only() {  # $1 status line — clock/banner tick without touching the frame
  printf '\033[H%s\033[K\033[H' "$1"
}

last_frame='' last_hash='' last_ok=0 poll="$POLL_MIN" started="$(date +%s)"

while true; do
  rows="$( (( TTY )) && tput lines 2>/dev/null || echo 40 )"
  cols="$( (( TTY )) && tput cols  2>/dev/null || echo 200 )"
  n_lines="${TCX_STREAM_LINES:-$(( rows > 1 ? rows - 1 : 40 ))}"

  # ── capture one frame ──────────────────────────────────────────
  rc=0 frame='' err=''
  if [[ -z "$PIN_W" ]] && ! [[ -s "$TARGET_FILE" ]]; then
    frame=$'\033[33m  no target set — run:  tcx.sh pick\033[0m'
    last_ok="$(date +%s)"        # not an outage, just unconfigured
  else
    # capture with in-tick retries: a read is idempotent, and on a flapping
    # uplink most single connect failures succeed on the immediate retry —
    # FROZEN should mean "the line is down", not "one SYN got lost".
    attempt=0
    while :; do
      rc=0
      frame="$(capture_frame "$n_lines" 2>"$ERRF")" || rc=$?
      (( rc == 0 )) && break
      (( attempt >= RETRIES )) && break
      attempt=$(( attempt + 1 )); sleep 1
    done
    # the failure's OWN words: a tcx: line, else the exception line a python
    # traceback ends with — never the raw tail (which is '}' on JSON errors)
    err="$(grep -m1 '^tcx:' "$ERRF" || grep -E 'Error|error|refused|route|timed' "$ERRF" | tail -n 1 || grep -v '^[[:space:]]*$' "$ERRF" | tail -n 1 || true)"
    err="${err##*( )}"; err="${err:0:40}"
    if (( rc == 0 )); then
      last_ok="$(date +%s)"
    else
      frame="$last_frame"        # NEVER wipe to an error screen — freeze
    fi
  fi

  # width-clamp so a long line can never wrap and shift the whole frame
  frame="$(awk -v c="$cols" '{ print substr($0, 1, c) }' <<< "$frame")"

  # ── status line ────────────────────────────────────────────────
  target='—'
  if [[ -n "$PIN_W" ]]; then target="$PIN_W $PIN_P"
  elif [[ -s "$TARGET_FILE" ]]; then target="$(tr '\t' ' ' < "$TARGET_FILE")"; fi
  now="$(date +%s)"
  status="$(printf '\033[2m %s  %s  [poll %ss]\033[0m' "$(date +'%H:%M:%S')" "$target" "$poll")"
  if (( rc != 0 )); then
    (( last_ok == 0 )) && last_ok="$started"
    status+="$(printf '  \033[2;31mFROZEN %ss — %s\033[0m' "$(( now - last_ok ))" "${err:-capture failed (no error text)}")"
  fi
  # clamp the VISIBLE status to the terminal width: a wrapped status line
  # spills its tail onto the frame's first row, where it sticks as residue
  plain="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$status")"
  if (( ${#plain} >= cols )); then
    status="${plain:0:cols-1}"
  fi

  # ── repaint only on change (or resize); otherwise just tick the clock ──
  hash="$(cksum <<< "${frame}|${rows}x${cols}")"
  if (( TTY == 0 )); then
    printf '%s\n%s\n\n' "$status" "$frame"          # no tty: plain sequential dump
  elif [[ "$hash" != "$last_hash" || "$RESIZED" == 1 ]]; then
    paint "$status" "$frame" "$cols"
    RESIZED=0
    poll="$POLL_MIN"                                 # activity → snap back to fast
  else
    paint_status_only "$status"
    (( poll < POLL_MAX )) && poll=$(( poll + 1 ))    # idle → back off 1,2,…,POLL_MAX
  fi
  last_frame="$frame"; last_hash="$hash"

  sleep "$poll" & SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || kill "$SLEEP_PID" 2>/dev/null   # WINCH interrupts instantly
done
