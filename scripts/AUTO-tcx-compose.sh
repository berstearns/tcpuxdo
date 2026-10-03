#!/usr/bin/env bash
# AUTO-tcx-compose.sh — interactive compose TUI for the tcpuxdo chat channel.
#
# WHAT: a message composer for the saved target pane, one layer above
#   `tcx-cli send`: a readline REPL where Enter sends the line, and `:e`
#   (or the -e editor-loop mode) opens YOUR editor — nvim, vim, whatever
#   $TCX_EDITOR/$VISUAL/$EDITOR says — on a per-twin compose file whose
#   whole content is sent as ONE prompt on save-and-quit. Multi-line is
#   safe end-to-end: delivery reuses `tcx.sh sendfile` (worker types the
#   payload literally, only the trailing Enter submits).
#
# WHY: typing `tcx-cli send '…'` for every message is friction, and single
#   quotes make real prose (apostrophes, newlines) painful. This is the
#   "Claude-Code-pane-like" input box for the cockpit's send pane. It is
#   ADDITIVE: tcx.sh / tcx-cli are untouched and keep working as before.
#
# INPUTS:
#   argv:  (none) = REPL · -e = editor loop · -h/--help
#   env:   TCX_EDITOR > VISUAL > EDITOR > nvim > vim > vi   (editor pick)
#          TCX_GROUP   cockpit twin namespace (passed through to tcx.sh;
#                      pins target, history and compose file to THAT twin)
# OUTPUTS: tcx.sh's own send/queue confirmations; compose file kept at
#   ${XDG_CACHE_HOME:-~/.cache}/tcpuxdo[/GROUP]/compose.md — NEVER deleted
#   on a failed send, so no draft is ever lost.
# EXIT: 0 ok · 1 no target/editor · 64 usage
#
# USAGE (combinatorial):
#   tcx-compose                  # REPL: TEXT⏎ send · :e editor · :r [N] read
#                                #       :t [Q] retarget · :p panes · :q quit
#   tcx-compose -e               # live in the editor: :wq sends + reopens,
#                                #   empty buffer or :cq (nonzero exit) quits
#   TCX_GROUP=gge tcx-compose    # compose for THAT twin's pane
#   TCX_EDITOR=nvim tcx-compose -e
#
# RE-RUN SAFETY: every send is an explicit user action (Enter / :wq);
#   nothing auto-sends. Reads are read-only. Safe to kill and restart.

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCX="$HERE/../tcx.sh"
CLI="$HERE/AUTO-tcx-cli.sh"          # for :enter — the bare-Enter verb lives there
[[ -x "$TCX" ]] || { echo "tcx-compose: engine missing: $TCX" >&2; exit 1; }

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo${TCX_GROUP:+/$TCX_GROUP}"
TARGET_FILE="$STATE_DIR/target"
HIST_FILE="$STATE_DIR/history"       # shared with tcx.sh chat on purpose
COMPOSE_FILE="$STATE_DIR/compose.md"

C_DIM=$'\033[2m'; C_CY=$'\033[36m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_X=$'\033[0m'
[[ -t 1 ]] || { C_DIM=''; C_CY=''; C_GRN=''; C_RED=''; C_X=''; }

usage() {
  cat <<EOF
usage: tcx-compose [-e]
  (none)   REPL: TEXT⏎ send · :e editor · :r [N] read · :t [Q] retarget
           :enter bare Enter (no text) · :p panes · :q quit
           (Ctrl-D quits too; Ctrl-C discards the line)
  -e       editor loop: save+quit sends and reopens; empty buffer or
           :cq (nonzero editor exit) quits. Draft survives failed sends
           at $COMPOSE_FILE
EOF
}

pick_editor() {
  local e
  for e in "${TCX_EDITOR:-}" "${VISUAL:-}" "${EDITOR:-}" nvim vim vi; do
    [[ -n "$e" ]] && command -v "${e%% *}" >/dev/null 2>&1 && { echo "$e"; return 0; }
  done
  echo "tcx-compose: no editor found (set TCX_EDITOR / EDITOR)" >&2; return 1
}

require_target() {
  [[ -s "$TARGET_FILE" ]] && return 0
  echo "tcx-compose: no target — picking one…" >&2
  "$TCX" pick || return 1
}

target_str() { tr '\t' ' ' < "$TARGET_FILE" 2>/dev/null || echo '—'; }

# send the compose file as one prompt; keep the draft unless it was delivered
send_compose_file() {
  if "$TCX" sendfile "$COMPOSE_FILE"; then
    : > "$COMPOSE_FILE"
    printf '%s✓ sent (%s)%s\n' "$C_GRN" "$(target_str)" "$C_X"
    return 0
  fi
  printf '%s✗ NOT sent — draft kept at %s%s\n' "$C_RED" "$COMPOSE_FILE" "$C_X" >&2
  return 1
}

edit_once() {  # returns: 0 = sent or nothing to send · 1 = send failed · 2 = user quit editor loop
  local ed; ed="$(pick_editor)" || return 2   # no editor = nothing to loop on
  # shellcheck disable=SC2086 — $ed may carry flags ("nvim -u NONE")
  $ed "$COMPOSE_FILE"; local erc=$?
  (( erc != 0 )) && return 2                       # :cq / editor abort = deliberate quit
  if ! grep -q '[^[:space:]]' "$COMPOSE_FILE" 2>/dev/null; then
    printf '%sempty buffer — nothing sent%s\n' "$C_DIM" "$C_X"
    return 3
  fi
  send_compose_file
}

editor_loop() {
  require_target || exit 1
  mkdir -p "$STATE_DIR"; : >> "$COMPOSE_FILE"
  printf '%seditor loop → %s · :wq sends+reopens · empty buffer or :cq quits%s\n' \
    "$C_DIM" "$(target_str)" "$C_X"
  local rc
  while true; do
    edit_once; rc=$?
    case $rc in
      0) continue ;;                               # sent → straight back in
      3) break ;;                                  # empty = done
      2) printf '%seditor quit — leaving%s\n' "$C_DIM" "$C_X"; break ;;
      *) read -r -p "send failed — Enter reopens the draft, Ctrl-C leaves: " _ || break ;;
    esac
  done
}

repl() {
  require_target || exit 1
  mkdir -p "$STATE_DIR"; : >> "$HIST_FILE"; : >> "$COMPOSE_FILE"
  history -c; while IFS= read -r h; do history -s "$h"; done < "$HIST_FILE"
  printf '%stcx-compose → %s   :e editor  :r read  :t retarget  :enter ⏎  :p panes  :q quit%s\n' \
    "$C_DIM" "$(target_str)" "$C_X"
  trap ':' INT                                     # Ctrl-C discards the line, not the TUI
  local line rc
  while true; do
    if ! IFS= read -r -e -p "$(printf '\001%s\002%s\001%s\002 ❯ ' "$C_CY" "$(target_str)" "$C_X")" line; then
      rc=$?; (( rc > 128 )) && { echo; continue; } # interrupted read = discard
      echo; break                                  # Ctrl-D = quit
    fi
    case "$line" in
      '')          continue ;;
      :q|:quit)    break ;;
      :h|:help|\?) usage; continue ;;
      :e|:edit)    edit_once || true; continue ;;
      :r)          "$TCX" read || true; continue ;;
      :r\ *)       "$TCX" read "${line#:r }" || true; continue ;;
      :t)          "$TCX" pick || true; continue ;;
      :t\ *)       "$TCX" pick "${line#:t }" || true; continue ;;
      :enter|:cr)  bash "$CLI" enter || true; continue ;;
      :p|:panes)   "$TCX" panes | cut -f3 || true; continue ;;
      :*)          echo "  :e editor  :r [N] read  :t [Q] retarget  :enter bare Enter  :p panes  :q quit"; continue ;;
    esac
    history -s "$line"; printf '%s\n' "$line" >> "$HIST_FILE"
    "$TCX" send "$line" || printf '%s✗ NOT sent — line kept in history (↑)%s\n' "$C_RED" "$C_X" >&2
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -e)        editor_loop ;;
  '')        repl ;;
  *)         echo "tcx-compose: unknown arg '$1'" >&2; usage >&2; exit 64 ;;
esac
