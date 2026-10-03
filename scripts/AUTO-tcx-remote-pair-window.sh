#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-pair-window.sh <profile> — the program every
#          ~/.config/i3minator/remote-<profile>.yml window runs. Builds the PAIR:
#            remote: <session> on the profile's worker, running claude
#            local : remote-<profile> (tcx-send + tcx-stream)
#          answers claude's first-run trust dialog, turns tcx-send into the
#          tcx-compose REPL (type a prompt, Enter sends it to the remote
#          claude), pins both panes to this pair (TCX_GROUP=<session>), attaches.
#
# WHY:     i3 splits an `exec` line on ';' and ',', so a multi-command
#          `zsh -lc '…; …'` inside an i3minator `cmd:` never reaches wezterm —
#          the swallow placeholder stays empty (the 2026-10-02 "black screen").
#          One program per window keeps the i3 line free of separators, and is
#          tracked instead of living as an inline snippet in YAML.
#
# INPUTS:  <profile>  a line name in ${TCX_COCKPIT_PROFILES_FILE:-
#                     ~/.config/tcx-cockpit/profiles.conf}  (name:worker:session:dir)
#
# OUTPUTS: an attached tmux client on remote-<profile>. On ANY failure the
#          window stays open on a shell with the error printed above it —
#          a silent close or a black window is never an outcome.
#          exit: the shell's exit (interactive window)
#
# RE-RUN SAFETY: idempotent — AUTO-tcx-cockpit.sh reuses both halves, and
#          AUTO-tcx-remote-trust.sh sends nothing when claude is already ready.
#===============================================================================
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
P="${1:-}"

hold(){ echo; echo "[remote-pair ${P:-?}] $1 — shell kept open"; exec "${SHELL:-zsh}"; }

[[ -n "$P" ]] || hold "usage: AUTO-tcx-remote-pair-window.sh <profile>"
line="$(grep -v '^[[:space:]]*#' "$CONF" 2>/dev/null | grep -m1 "^${P}:")" \
    || hold "no profile '$P' in $CONF"
IFS=':' read -r _ W S _ <<<"$line"

# Same default as tcx-claude: the remote agent runs without per-tool permission
# prompts, so it never blocks on a dialog nobody is watching on the worker
# (2026-10-02, Bernardo: a remote pair stuck on "Do you want to proceed?" is a
# failed setup). Override per launch with TCX_COCKPIT_CLAUDE_CMD.
export TCX_COCKPIT_CLAUDE_CMD="${TCX_COCKPIT_CLAUDE_CMD:-claude --dangerously-skip-permissions}"
# The LOCAL twin session is named like the launcher: remote-<profile>
# (2026-10-03, Bernardo: every twin session must carry the remote- prefix).
LS="remote-$P"
export TCX_COCKPIT_LOCAL_SESSION="$LS"
# Local project dir = cwd of every local pane of remote-<profile> (2026-10-03,
# Bernardo: panes must start in the project folder, not in tcpuxdo or ~/runs).
LD="$(awk -F'\t' -v p="$P" '$1==p{print $2; exit}' "${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}" 2>/dev/null)"
[[ -d "$LD" ]] || LD="$HOME"

"$HERE/AUTO-tcx-cockpit.sh" -p "$P" || hold "AUTO-tcx-cockpit.sh failed (rc=$?)"

# Pin THIS pair to its own target (TCX_GROUP=<session>). The cockpit only
# writes the SHARED target, so two open pairs would steal each other's stream
# and sends. Read the shared file right after the cockpit wrote it, then copy
# it into the group namespace through tcx.sh's own writer.
TARGET="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/target"
IFS=$'\t' read -r TW TP < "$TARGET" || hold "cockpit wrote no target file"
TCX_GROUP="$S" "$HERE/../tcx.sh" use "$TW" "$TP" >/dev/null || hold "tcx.sh use $TW $TP failed"

"$HERE/AUTO-tcx-remote-trust.sh" "$TW" "$TP" || echo "[remote-pair $P] WARN: trust step did not reach 'ready' — check tcx-stream"

# Make the two local panes usable: tcx-send becomes the tcx-compose REPL (type
# a prompt, Enter sends it to the remote claude; :e opens your editor) and
# tcx-stream follows the group target. Panes are found by TITLE; a pane that
# already runs the grouped program is left alone, so a draft is never killed.
# LS (remote-<profile>) is set above, before the cockpit call
pane_by_title(){ tmux list-panes -s -t "=$LS:" -F '#{pane_id}'$'\t''#{pane_title}' | awk -F'\t' -v t="$1" '$2==t{print $1}'; }
respawn(){  # $1 title  $2 command
    local id; id="$(pane_by_title "$1")"
    [[ -n "$id" && "$(grep -c . <<<"$id")" == 1 ]] || { echo "[remote-pair $P] WARN: pane '$1' missing or duplicated"; return 1; }
    [[ "$(tmux display -p -t "$id" '#{pane_start_command}')" == *"TCX_GROUP=$S "* \
       && "$(tmux display -p -t "$id" '#{pane_current_path}')" == "$LD" ]] && return 0
    tmux respawn-pane -k -t "$id" -c "$LD" "$2"
    tmux select-pane -t "$id" -T "$1"
}
respawn tcx-stream "TCX_GROUP=$S bash $HERE/../setup/tcx-stream.sh"
respawn tcx-send   "TCX_GROUP=$S $HERE/AUTO-tcx-compose.sh; exec ${SHELL:-zsh}"
# Second pair for plain bash: remote terminal in the repo + local window
# "shell" (sh-send | sh-stream). Idempotent; a failure only warns.
"$HERE/AUTO-tcx-remote-shell-twin.sh" "$P" || echo "[remote-pair $P] WARN: shell twin not ready — re-run AUTO-tcx-remote-shell-twin.sh $P"
tmux select-pane -t "$(pane_by_title tcx-send)" 2>/dev/null

if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "=$LS"  # already inside tmux: switch the client
else
    tmux attach -t "=$LS" -c "$LD"   # terminal outside tmux: attach
fi
hold "detached from $LS (worker $W)"
