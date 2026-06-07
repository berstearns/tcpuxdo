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
#   :t                     retarget (fzf picker)
#   :r [N]                 read/capture the target pane (N lines of scrollback)
#   :l                     list nodes + panes
#   :q   (or Ctrl-D)       quit
#   ↑ / ↓                  recall previous prompts
#
# Non-interactive (bind these to keys):
#   tcx.sh pick            (re)pick the target pane, save, exit
#   tcx.sh send 'TEXT'     submit TEXT to the fixed target
#   tcx.sh read [N]        capture the last target pane → stdout
#   tcx.sh target          print the fixed target  (worker pane)
#===============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/tcpuxdo"
ENV_FILE="$HERE/.env"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE — cp .env.example .env and fill it in"; exit 1; }
set -o allexport; . "$ENV_FILE"; set +o allexport

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo"
TARGET_FILE="$STATE_DIR/target"      # one line: "worker<TAB>pane"
HIST_FILE="$STATE_DIR/history"       # one prompt per line

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

# ── fzf pane picker (the only direct relay read) ─────────────────
# Emits  worker<TAB>pane<TAB>pretty  ; fzf shows only the pretty column.
pick_target() {
  local sel w p
  sel="$(
    PYTHONPATH="$HERE" python3 - <<'PY' | fzf --ansi --delimiter=$'\t' \
        --with-nth=3 --nth=3 --height=40% --reverse \
        --prompt='target> ' --header='pick a pane'
import os
from proto import rpc
r = rpc(os.environ["TCPUX_HOST"], int(os.environ["TCPUX_PORT"]), {"op": "state"})
state = r.get("state", {})
G = "\033[32m"; Y = "\033[33m"; D = "\033[2m"; X = "\033[0m"
for w in sorted(state):
    panes = state[w].get("panes", {})
    for pid in sorted(panes):
        p = panes[pid]
        flag = (Y + "busy" + X) if p.get("busy") else (G + "idle" + X)
        pretty = f"{w:<16}{D}{pid:<14}{X}[{flag}] {p.get('cmd','?')}"
        print(f"{w}\t{pid}\t{pretty}")
PY
  )" || return 1
  [[ -n "$sel" ]] || return 1
  w="$(cut -f1 <<<"$sel")"; p="$(cut -f2 <<<"$sel")"
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$w" "$p" > "$TARGET_FILE"
  W="$w"; P="$p"
}

# ── actions (delegate to tcpuxdo) ────────────────────────────────
submit()  { "$TCPUXDO" -w "$W" -p "$P" -c "$1"; }
do_list() { "$TCPUXDO" list; }
do_read() {  # $1 optional line count
  if [[ -n "${1:-}" ]]; then "$TCPUXDO" read -w "$W" -p "$P" --lines "$1"
  else "$TCPUXDO" read -w "$W" -p "$P"; fi
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
      :l|:list)     do_list; continue ;;
      :r)           do_read; echo; continue ;;
      :r\ *)        do_read "${line#:r }"; echo; continue ;;
      :*)           echo "  :t retarget   :r [N] read   :l list   :q quit"; continue ;;
    esac
    history -s "$line"; printf '%s\n' "$line" >> "$HIST_FILE"
    submit "$line"
  done
}

# ── entrypoint ───────────────────────────────────────────────────
case "${1:-}" in
  ""|chat)   chat_loop ;;
  pick)      pick_target && echo "$W $P" ;;
  send)      shift; require_target && submit "$*" ;;
  read|r)    shift; require_target && do_read "${1:-}" ;;
  target|t)  require_target && echo "$W $P" ;;
  -h|--help) sed -n '2,/^#====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^=*$/d' ;;
  *)         echo "unknown: $1  (try: pick | send 'TXT' | read [N] | target | --help)"; exit 1 ;;
esac
