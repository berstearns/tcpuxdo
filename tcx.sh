#!/usr/bin/env bash
#===============================================================================
# tcx — minimal TUI chat front-end for tcpuxdo.
#
# Fix a target pane ONCE, then just type prompts: every line you enter is
# submitted as a chat (send-keys + Enter) to that pane. The fixed target is
# always shown in the prompt, so there is nothing to remember.
#
# All relay logic lives in ./tcpuxdo — this file is only the front-end.
# The only direct relay call here is the fzf pane-picker (reads `state`).
#
# Interactive:
#   tcx.sh                 pick target (if unset) → chat loop
#
# In the chat loop:
#   <text><Enter>          submit <text> as a chat to the fixed target
#   :t                     retarget via the fzf picker
#   :t ALIAS|PANE          retarget by alias, else EXACT pane id — never fuzzy,
#                          and an unknown name is an error, not a picker
#   :a                     list aliases
#   :a NAME                bind the CURRENT target to the shortcut NAME
#   :p                     list panes (worker / pane / busy / cmd)
#   :r [N]                 read/capture the target pane (N lines of scrollback)
#   :l                     list nodes + panes
#   :q   (or Ctrl-D)       quit
#   ↑ / ↓                  recall previous prompts
#
# Non-interactive (bind these to keys, or script them):
#   tcx.sh pick [QUERY]    (re)pick the target pane, save, exit
#   tcx.sh use ARG         retarget with NO ui. ARG is an alias if one matches
#                          exactly, else a query that must hit exactly one pane.
#   tcx.sh use -q QUERY    force query mode, ignoring aliases
#   tcx.sh use WORKER PANE retarget to an exact worker/pane, no relay read at all
#   tcx.sh alias ls        list shortcuts
#   tcx.sh alias add N [Q] bind shortcut N to Q's pane (or to the current target)
#   tcx.sh alias rm N      drop a shortcut
#   tcx.sh panes           machine-readable inventory: worker<TAB>pane<TAB>pretty
#   tcx.sh send 'TEXT'     submit TEXT to the fixed target
#   tcx.sh sendfile F [P]  submit F's whole content as ONE prompt (P = preamble)
#   tcx.sh read [N]        capture the last target pane → stdout
#   tcx.sh target          print the fixed target  (worker pane)
#
# The target lives in one file that the chat loop re-reads before every prompt,
# so `tcx.sh use …` from any other shell retargets an already-running TUI.
#===============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/tcpuxdo"
ENV_FILE="$HERE/.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE — cp .env.example .env and fill it in"; exit 1; }
set -o allexport; . "$ENV_FILE"; set +o allexport

# One target file per messenger GROUP, not one per machine.
#
# Keying this by (machine) alone is the defect that forced the shared-target-owner
# fence: N messenger instances on m1 shared ONE mutable target file, so any
# `tcx.sh use` could silently redirect another instance's in-flight send — the
# 2026-07-21 incidents #1/#2 (res-messenger -> claude4:0:0, four times, undetected).
# The fence was a procedural workaround for a missing key dimension. Adding the
# dimension retires the workaround: with TCX_GROUP set, two instances cannot
# collide because they no longer share the file.
#
# TCX_GROUP unset => byte-identical behaviour to before (the human's own TUI).
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo${TCX_GROUP:+/$TCX_GROUP}"
TARGET_FILE="$STATE_DIR/target"      # one line: "worker<TAB>pane"
HIST_FILE="$STATE_DIR/history"       # one prompt per line
ALIAS_FILE="$STATE_DIR/aliases"      # "name<TAB>worker<TAB>pane" per line

C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_CY=$'\033[1;36m'; C_X=$'\033[0m'

# ── target persistence ───────────────────────────────────────────
have_target() { [[ -s "$TARGET_FILE" ]]; }

load_target() {  # sets globals W and P; returns 1 if unset
  have_target || return 1
  IFS=$'\t' read -r W P < "$TARGET_FILE"
  [[ -n "${W:-}" && -n "${P:-}" ]]
}

require_target() {
  load_target && return 0
  echo "no target set — run:  $(basename "$0") pick" >&2
  return 1
}

# ── pane inventory (the only direct relay read) ──────────────────
# Emits  worker<TAB>pane<TAB>pretty  ; the pretty column is what you match on.
pane_lines() {
  PYTHONPATH="$HERE" python3 - <<'PY'
import os
from proto import rpc
r = rpc(os.environ["TCPUX_HOST"], int(os.environ["TCPUX_PORT"]), {"op": "state"})
state = r.get("state", {})
color = os.environ.get("TCX_COLOR") == "1"
G, Y, D, X = ("\033[32m", "\033[33m", "\033[2m", "\033[0m") if color else ("",) * 4
for w in sorted(state):
    panes = state[w].get("panes", {})
    for pid in sorted(panes):
        p = panes[pid]
        flag = (Y + "busy" + X) if p.get("busy") else (G + "idle" + X)
        pretty = f"{w:<16}{D}{pid:<14}{X}[{flag}] {p.get('cmd','?')}"
        print(f"{w}\t{pid}\t{pretty}")
PY
}

save_target() {  # $1 worker  $2 pane
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$1" "$2" > "$TARGET_FILE"
  W="$1"; P="$2"
}

# ── aliases: short names bound to a concrete worker/pane ─────────
# Names are restricted so they can never contain a tab and corrupt the store.
valid_alias_name() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }

alias_lookup() {  # $1 name -> prints "worker<TAB>pane", or returns 1
  local hit
  [[ -s "$ALIAS_FILE" ]] || return 1
  hit="$(awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' "$ALIAS_FILE")"
  [[ -n "$hit" ]] || return 1
  printf '%s\n' "$hit"
}

alias_set() {  # $1 name  $2 worker  $3 pane
  valid_alias_name "$1" || { echo "bad alias name: $1 (use letters/digits/_.-)" >&2; return 1; }
  mkdir -p "$STATE_DIR"; : >> "$ALIAS_FILE"
  local tmp="$ALIAS_FILE.tmp"
  awk -F'\t' -v n="$1" '$1 != n' "$ALIAS_FILE" > "$tmp"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
  sort -o "$tmp" "$tmp" && mv "$tmp" "$ALIAS_FILE"
}

alias_rm() {  # $1 name
  [[ -s "$ALIAS_FILE" ]] || { echo "no aliases defined" >&2; return 1; }
  alias_lookup "$1" >/dev/null || { echo "no such alias: $1" >&2; return 1; }
  local tmp="$ALIAS_FILE.tmp"
  awk -F'\t' -v n="$1" '$1 != n' "$ALIAS_FILE" > "$tmp" && mv "$tmp" "$ALIAS_FILE"
  echo "removed $1"
}

alias_ls() {
  [[ -s "$ALIAS_FILE" ]] || { echo "${C_DIM}(no aliases — try: tcx.sh alias add <name>)${C_X}"; return 0; }
  awk -F'\t' -v c="$C_CY" -v x="$C_X" \
      '{ printf "  %s%-10s%s %-12s %s\n", c, $1, x, $2, $3 }' "$ALIAS_FILE"
}

# CLI retarget: alias first (exact), then free-text query. Never opens a UI.
use_arg() {  # $1 arg
  local a
  if a="$(alias_lookup "$1")"; then
    save_target "$(cut -f1 <<<"$a")" "$(cut -f2 <<<"$a")"
    echo "$1 = $W $P"; return 0
  fi
  resolve_target "$1" && echo "$W $P"
}

# Exact pane match — no fuzz, no substrings. ARG matches either the bare pane id
# ("tcpuxdo-worker:2:0") or a fully-qualified "worker/pane". A bare pane id that
# exists on more than one worker is ambiguous, not a coin flip.
exact_target() {  # $1 arg
  local lines n
  lines="$(pane_lines | awk -F'\t' -v a="$1" '$2 == a || ($1 "/" $2) == a')"
  n="$(grep -c . <<<"${lines:-}" || true)"
  if [[ "$n" == 1 ]]; then
    save_target "$(cut -f1 <<<"$lines")" "$(cut -f2 <<<"$lines")"
    return 0
  fi
  if [[ "$n" != 0 ]]; then
    echo "ambiguous: '$1' exists on $n workers — qualify it as worker/pane:" >&2
    awk -F'\t' '{ print "  " $1 "/" $2 }' <<<"$lines" >&2
    return 2          # reported already; caller must not add "not found"
  fi
  return 1            # genuinely no match
}

# Interactive retarget for ":t ARG": alias first, then an EXACT pane match.
# No fuzzy fallback and no picker — an unknown ARG is an error, so a typo can
# never silently land you on some other worker's pane.
smart_retarget() {  # $1 arg
  local a
  if a="$(alias_lookup "$1")"; then
    save_target "$(cut -f1 <<<"$a")" "$(cut -f2 <<<"$a")"; return 0
  fi
  local rc=0
  exact_target "$1" || rc=$?          # guarded: bare `cmd && ...` would trip set -e
  case "$rc" in
    0) return 0 ;;
    2) return 1 ;;                    # ambiguity already printed by exact_target
    *) echo "not found: $1  (no such alias or pane — :a lists aliases, :p lists panes)" >&2
       return 1 ;;
  esac
}

# Resolve a free-text query against the pane inventory. Exactly one match wins;
# zero or many is an error (with the candidates on stderr) so callers can react.
resolve_target() {  # $1 query
  local lines n
  lines="$(pane_lines | grep -i -- "$1" || true)"
  n="$(grep -c . <<<"${lines:-}" || true)"
  if [[ "$n" == 1 ]]; then
    save_target "$(cut -f1 <<<"$lines")" "$(cut -f2 <<<"$lines")"
    return 0
  fi
  if [[ "$n" == 0 ]]; then echo "no pane matches: $1" >&2
  else echo "ambiguous ($n matches for '$1'):" >&2; cut -f3 <<<"$lines" >&2; fi
  return 1
}

# fzf picker — interactive fallback. Called with no query it behaves exactly as
# it always has: always show the UI, never auto-resolve. A query pre-filters and
# opts into --select-1/--exit-0, so a query narrowing to one pane skips the UI.
pick_target() {  # $1 optional query
  local sel
  local -a auto=()
  if [[ -n "${1:-}" ]]; then auto=(--select-1 --exit-0 --query="$1"); fi
  # NO --nth here: --with-nth=3 collapses the display to a single field, so any
  # --nth>1 indexes past the end and fzf matches nothing at all.
  sel="$(TCX_COLOR=1 pane_lines | fzf --ansi --delimiter=$'\t' \
      --with-nth=3 --height=40% --reverse "${auto[@]}" \
      --prompt='target> ' --header='pick a pane')" || return 1
  [[ -n "$sel" ]] || return 1
  save_target "$(cut -f1 <<<"$sel")" "$(cut -f2 <<<"$sel")"
}

# ── actions (delegate to tcpuxdo) ────────────────────────────────
# --no-cascade by default. tcpuxdo's client auto-creates the target on
# SK3_PANE_NOT_EXIST (create-session → window → pane) and retries. For a CHAT
# front-end that is never right: you are addressing a pane that already exists,
# so a stale or mistyped target would silently spawn a NEW session and type your
# prompt into a fresh shell — where a multi-line payload executes line by line.
# Set TCX_CASCADE=1 if you really want the ladder built for you.
submit()  {
  local casc=(--no-cascade)
  if [[ "${TCX_CASCADE:-0}" == 1 ]]; then casc=(); fi
  "$TCPUXDO" -w "$W" -p "$P" -c "$1" "${casc[@]}"
}

# Send a whole file as ONE prompt. This is safe because worker.py sends the
# payload with `send-keys -l` (literal) and the submitting Enter as a separate
# keystroke — so embedded newlines land as newlines *inside* the input box and
# only the trailing Enter submits. A naive multi-line send would otherwise fire
# one prompt per line.
#
# Ceilings: proto.py frames at MAX_FRAME = 1 MiB for the whole JSON message, so
# the payload must stay well under that once escaped. Default cap 256 KiB.
#
# The tighter real limit is tmux's: a single `send-keys` command string caps at
# ~16 KB (measured: 8 KB ok, 16 KB "command too long", and NOTHING is typed).
# worker.py splits the payload into SEND_CHUNK_BYTES pieces to get past that —
# so anything over ~8 KB needs a worker new enough to chunk. Against an old
# worker a large sendfile fails with tmux "command too long"; check with
#   tcpuxdo --op status --id <id>
TCX_MAX_BYTES="${TCX_MAX_BYTES:-262144}"

submit_file() {  # $1 path  $2 optional preamble line
  local f="$1" preamble="${2:-}" bytes body
  [[ -f "$f" ]] || { echo "no such file: $f" >&2; return 1; }
  bytes="$(wc -c < "$f")"
  if (( bytes > TCX_MAX_BYTES )); then
    echo "refusing: $f is ${bytes}B > TCX_MAX_BYTES=${TCX_MAX_BYTES}" >&2
    echo "  (proto.py frames at 1 MiB; raise TCX_MAX_BYTES to override)" >&2
    return 1
  fi
  body="$(cat -- "$f")"
  [[ -n "$body" ]] || { echo "refusing: $f is empty (SK4_BAD_CMD)" >&2; return 1; }
  if [[ -n "$preamble" ]]; then body="$preamble"$'\n\n'"$body"; fi
  echo "sending $f (${bytes}B) → $W $P" >&2
  submit "$body"
}
do_list() { "$TCPUXDO" list; }
do_read() {  # $1 optional line count; TCX_READ_WAIT caps blocking (default 30s)
  local wait="${TCX_READ_WAIT:-30}"
  if [[ -n "${1:-}" ]]; then "$TCPUXDO" read -w "$W" -p "$P" --lines "$1" --wait "$wait"
  else "$TCPUXDO" read -w "$W" -p "$P" --wait "$wait"; fi
}

prompt_str() {  # \001..\002 wrap non-printing bytes so readline counts width right
  printf '\001%s\002%s\001%s\002 \001%s\002%s\001%s\002 ❯ ' \
    "$C_DIM" "$W" "$C_X" "$C_CY" "$P" "$C_X"
}

# ── interactive chat loop ────────────────────────────────────────
chat_loop() {
  load_target || pick_target || { echo "no target — aborting"; exit 1; }
  mkdir -p "$STATE_DIR"; : >> "$HIST_FILE"
  history -c; while IFS= read -r h; do history -s "$h"; done < "$HIST_FILE"

  printf '%starget%s %s %s   %s:t%s retarget  %s:r%s read  %s:l%s list  %s:q%s quit%s\n' \
    "$C_B" "$C_X" "$W" "$P" "$C_DIM" "$C_X" "$C_DIM" "$C_X" "$C_DIM" "$C_X" "$C_DIM" "$C_X" ""

  local line
  while load_target; do
    if ! IFS= read -r -e -p "$(prompt_str)" line; then echo; break; fi   # Ctrl-D
    [[ -z "$line" ]] && continue
    case "$line" in
      :q|:quit)     break ;;
      :t|:target)   pick_target && echo "→ $W $P" || echo "(unchanged)"; continue ;;
      :t\ *|:target\ *)
                    smart_retarget "${line#* }" && echo "→ $W $P" || echo "(unchanged)"; continue ;;
      :a|:alias)    alias_ls; continue ;;
      :a\ *|:alias\ *)
                    # ":a <name>" binds the CURRENT target to <name>
                    alias_set "${line#* }" "$W" "$P" && echo "→ ${line#* } = $W $P" || true
                    continue ;;
      :f\ *|:file\ *)
                    submit_file "${line#* }" || true; continue ;;
      :l|:list)     do_list; continue ;;
      :p|:panes)    TCX_COLOR=1 pane_lines | cut -f3; continue ;;
      :r)           do_read; echo; continue ;;
      :r\ *)        do_read "${line#:r }"; echo; continue ;;
      :*)           echo "  :t [Q|alias] retarget   :a [name] aliases   :p panes   :r [N] read   :l list   :q quit"; continue ;;
    esac
    history -s "$line"; printf '%s\n' "$line" >> "$HIST_FILE"
    submit "$line"
  done
}

# ── entrypoint ───────────────────────────────────────────────────
case "${1:-}" in
  ""|chat)   chat_loop ;;
  pick)      shift; pick_target "${1:-}" && echo "$W $P" ;;
  use)       shift
             Q_ONLY=0
             if [[ "${1:-}" == "-q" ]]; then Q_ONLY=1; shift; fi
             case $# in
               1) if [[ "$Q_ONLY" == 1 ]]; then resolve_target "$1" && echo "$W $P"
                  else use_arg "$1"; fi ;;
               2) save_target "$1" "$2" && echo "$W $P" ;;
               *) echo "usage: use [-q] <alias|query> | use <worker> <pane>" >&2; exit 1 ;;
             esac ;;
  alias|a)   shift
             SUB="${1:-ls}"; [[ $# -gt 0 ]] && shift || true
             case "$SUB" in
               add|set)
                 [[ $# -ge 1 ]] || { echo "usage: alias add <name> [query]" >&2; exit 1; }
                 NAME="$1"; shift
                 if [[ $# -ge 1 ]]; then resolve_target "$*" || exit 1
                 else require_target || exit 1; fi
                 alias_set "$NAME" "$W" "$P" && echo "$NAME = $W $P" ;;
               rm|del)  [[ $# -ge 1 ]] || { echo "usage: alias rm <name>" >&2; exit 1; }
                        alias_rm "$1" ;;
               ls|list) alias_ls ;;
               *)       echo "usage: alias [ls | add <name> [query] | rm <name>]" >&2; exit 1 ;;
             esac ;;
  panes)     pane_lines ;;
  send)      shift; require_target && submit "$*" ;;
  sendfile|sf)
             shift
             [[ $# -ge 1 ]] || { echo "usage: sendfile <path> [preamble]" >&2; exit 1; }
             FPATH="$1"; shift
             require_target && submit_file "$FPATH" "${*:-}" ;;
  read|r)    shift; require_target && do_read "${1:-}" ;;
  target|t)  require_target && echo "$W $P" ;;
  -h|--help) sed -n '2,/^#====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^=*$/d' ;;
  *)         echo "unknown: $1  (try: pick | use | panes | send 'TXT' | read [N] | target | --help)"; exit 1 ;;
esac
