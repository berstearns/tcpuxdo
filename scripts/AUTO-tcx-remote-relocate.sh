#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-relocate.sh [-n] [--codex] <profile>… — move the
#          LOCAL panes of already-open tmux sessions remote-<profile> into the
#          project's local dir (~/.config/tcx-cockpit/local-dirs.tsv). Every pane
#          titled tcx-send, tcx-stream, sh-send or sh-stream whose cwd is wrong
#          (or whose program is broken) is respawned with its CANONICAL command,
#          rebuilt from its title — never copied from #{pane_start_command}.
#            tcx-send   TCX_GROUP=<session>    AUTO-tcx-compose.sh
#            tcx-stream TCX_GROUP=<session>    setup/tcx-stream.sh
#            sh-send    TCX_GROUP=<session>-sh AUTO-tcx-compose.sh
#            sh-stream  TCX_GROUP=<session>-sh setup/tcx-stream.sh
#          --codex also replaces codex-* panes by a fresh idle codex in the dir.
#
# WHY:     2026-10-03, Bernardo: "the remote- panes' work dirs are a complete
#          mess". First version re-used #{pane_start_command}; tmux returns it
#          WITH surrounding quotes, so the respawn ran "\"TCX_GROUP=…\"" and
#          broke every pane. Commands are now rebuilt from the title.
#
# INPUTS:  <profile>…  profiles (session remote-<profile> must exist)
#          -n          print what would be respawned, change nothing
#          --codex     also respawn codex-* panes (fresh codex in the dir)
# OUTPUTS: "relocate<TAB>session<TAB>pane<TAB>title<TAB>action<TAB>cwd-before"
#          exit 0 · 64 usage
# RE-RUN SAFETY: idempotent — a pane in the right dir running its canonical
#          program (python3/bash child of compose/stream) is left alone.
#===============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DIRS="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
DRY=0; CODEX=0
while [[ "${1:-}" == -* ]]; do case "$1" in
    -n) DRY=1 ;; --codex) CODEX=1 ;;
    *) echo "usage: AUTO-tcx-remote-relocate.sh [-n] [--codex] <profile>…" >&2; exit 64 ;;
esac; shift; done
(( $# )) || { echo "usage: AUTO-tcx-remote-relocate.sh [-n] [--codex] <profile>…" >&2; exit 64; }

for P in "$@"; do
    LS="remote-$P"
    LD="$(awk -F'\t' -v p="$P" '$1==p{print $2; exit}' "$DIRS")"
    line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${P}:")"
    IFS=':' read -r _ _ S _ <<<"$line"
    [[ -d "$LD" && -n "${S:-}" ]] || { printf 'relocate\t%s\t-\t-\tFAIL\tno local dir or profile for %s\n' "$LS" "$P"; continue; }
    tmux has-session -t "=$LS" 2>/dev/null || { printf 'relocate\t%s\t-\t-\tFAIL\tno such session\n' "$LS"; continue; }
    for id in $(tmux list-panes -s -t "=$LS:" -F '#{pane_id}'); do
        title="$(tmux display -p -t "$id" '#{pane_title}')"
        cwd="$(tmux display -p -t "$id" '#{pane_current_path}')"
        cur="$(tmux display -p -t "$id" '#{pane_current_command}')"
        cmd=""
        case "$title" in
            tcx-send)   cmd="TCX_GROUP=$S $HERE/AUTO-tcx-compose.sh; exec ${SHELL:-zsh}" ;;
            tcx-stream) cmd="TCX_GROUP=$S bash $REPO/setup/tcx-stream.sh" ;;
            sh-send)    cmd="TCX_GROUP=$S-sh $HERE/AUTO-tcx-compose.sh; exec ${SHELL:-zsh}" ;;
            sh-stream)  cmd="TCX_GROUP=$S-sh bash $REPO/setup/tcx-stream.sh" ;;
            codex-*)    (( CODEX )) && cmd="codex --dangerously-bypass-approvals-and-sandbox -C $(printf %q "$LD"); exec ${SHELL:-zsh}" ;;
        esac
        if [[ -z "$cmd" ]]; then act="left"
        elif [[ "$cwd" == "$LD" && "$title" != codex-* && "$cur" =~ ^(bash|python3|python)$ ]]; then act=ok
        elif [[ "$cwd" == "$LD" && "$title" == codex-* ]]; then act=ok
        elif (( DRY )); then act=would-respawn
        else
            tmux respawn-pane -k -t "$id" -c "$LD" "$cmd" && tmux select-pane -t "$id" -T "$title"
            act=respawned
        fi
        printf 'relocate\t%s\t%s\t%s\t%s\t%s\n' "$LS" "$id" "$title" "$act" "$cwd"
    done
done
