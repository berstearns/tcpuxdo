#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-pair-window.sh <profile> — the program every
#          ~/.config/i3minator/remote-<profile>.yml window runs. Builds the PAIR:
#            remote: <session> on the profile's worker, running claude
#            local : remote-<profile> (tcx-send + tcx-stream)
#          Also adds a remote command shell and git shell, and a local manager
#          window with Codex plus two project shells, matching wedding-meta.
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
if [[ "$P" == rag-papers-gcp-repo ]]; then
    instruction_url="https://raw.githubusercontent.com/berstearns/tcpuxdo/master/scripts/prompts/rag-papers-gcp-repo-remote-worker.md"
    export TCX_COCKPIT_CLAUDE_CMD="${TCX_COCKPIT_CLAUDE_CMD:-claude --dangerously-skip-permissions \"Read $instruction_url and follow it. Report if you cannot read it.\"}"
else
    export TCX_COCKPIT_CLAUDE_CMD="${TCX_COCKPIT_CLAUDE_CMD:-claude --dangerously-skip-permissions}"
fi
# The LOCAL twin session is named like the launcher: remote-<profile>
# (2026-10-03, Bernardo: every twin session must carry the remote- prefix).
LS="remote-$P"
export TCX_COCKPIT_LOCAL_SESSION="$LS"
# Local project dir = cwd of every local pane of remote-<profile> (2026-10-03,
# Bernardo: panes must start in the project folder, not in tcpuxdo or ~/runs).
LD="$(awk -F'\t' -v p="$P" '$1==p{print $2; exit}' "${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}" 2>/dev/null)"
[[ -d "$LD" ]] || LD="$HOME"

# A project tmuxinator config defines the initial three-window layout. Existing
# sessions are reconciled below, so reopening i3minator never duplicates it.
tmuxinator_created=0
if [[ -f "$HOME/.config/tmuxinator/$LS.yml" ]] && ! tmux has-session -t "=$LS" 2>/dev/null; then
    tmuxinator start --no-attach "$LS" || hold "tmuxinator could not create $LS"
    tmuxinator_created=1
    for _ in {1..30}; do
        titles="$(tmux list-panes -s -t "=$LS:" -F '#{pane_title}' 2>/dev/null)"
        [[ "$titles" == *tcx-send* && "$titles" == *tcx-stream* && "$titles" == *remote-manager* && "$titles" == *sh-send* && "$titles" == *sh-stream* ]] && break
        sleep 0.2
    done
fi

# A prior launcher can leave the send pane with a project-specific title.
# Recover the two-pane cockpit only when its other pane is the known stream.
if tmux has-session -t "=$LS" 2>/dev/null; then
    cockpit_panes="$(tmux list-panes -t "=$LS:cockpit" -F '#{pane_id}'$'\t''#{pane_title}' 2>/dev/null)"
    if [[ "$(wc -l <<<"$cockpit_panes")" == 2 ]] \
       && [[ "$(awk -F'\t' '$2=="tcx-stream"{n++} END{print n+0}' <<<"$cockpit_panes")" == 1 ]] \
       && [[ "$(awk -F'\t' '$2=="tcx-send"{n++} END{print n+0}' <<<"$cockpit_panes")" == 0 ]]; then
        stale_send="$(awk -F'\t' '$2!="tcx-stream"{print $1}' <<<"$cockpit_panes")"
        if [[ "$(tmux display -p -t "$stale_send" '#{pane_current_command}')" =~ ^(bash|zsh|sh)$ ]]; then
            tmux select-pane -t "$stale_send" -T tcx-send
            echo "[remote-pair $P] restored cockpit send pane title"
        fi
    fi
fi

"$HERE/AUTO-tcx-cockpit.sh" -p "$P" || hold "AUTO-tcx-cockpit.sh failed (rc=$?)"

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
# Mirror the working remote-wedding-meta local session: cockpit, a manager
# window with Codex and two shells, and the shell twin window.
manager_pane="$(pane_by_title remote-manager)"
if [[ -z "$manager_pane" ]]; then
    manager_pane="$(pane_by_title codex-main)"
    if [[ -n "$manager_pane" ]]; then
        tmux select-pane -t "$manager_pane" -T remote-manager
        tmux rename-window -t "$manager_pane" "codex-prep-$P"
    fi
fi
if [[ -z "$manager_pane" ]]; then
    manager_pane="$(tmux new-window -d -t "=$LS:" -n "codex-prep-$P" -c "$LD" -P -F '#{pane_id}' \
        "$HERE/AUTO-run-local-codex-agent-in-project-directory.sh $P")" \
        || hold "could not create local manager window in $LS"
    tmux select-pane -t "$manager_pane" -T remote-manager
elif (( ! tmuxinator_created )) && [[ "$(tmux display -p -t "$manager_pane" '#{pane_current_command}')" =~ ^(bash|zsh|sh)$ ]]; then
    tmux respawn-pane -k -t "$manager_pane" -c "$LD" \
        "$HERE/AUTO-run-local-codex-agent-in-project-directory.sh $P" \
        || hold "could not restart local manager Codex in $LS"
fi
manager_window="$(tmux display -p -t "$manager_pane" '#{window_id}')"
if (( $(tmux list-panes -t "$manager_window" -F '#{pane_id}' | wc -l) < 2 )); then
    tmux split-window -h -d -t "$manager_pane" -c "$LD" \
        || hold "could not add manager shell pane in $LS"
fi
if (( $(tmux list-panes -t "$manager_window" -F '#{pane_id}' | wc -l) < 3 )); then
    tmux split-window -v -d -t "$manager_pane" -c "$LD" \
        || hold "could not add second manager shell pane in $LS"
fi
tmux set-option -w -t "$manager_window" automatic-rename off
tmux set-option -p -t "$manager_pane" allow-set-title off 2>/dev/null || true

# Finish the local layout before relay checks. A temporary worker failure must
# not strand this twin with only its cockpit window.
TARGET="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/target"
IFS=$'\t' read -r TW TP < "$TARGET" || hold "cockpit wrote no target file"
TCX_GROUP="$S" "$HERE/../tcx.sh" use "$TW" "$TP" >/dev/null || hold "tcx.sh use $TW $TP failed"
"$HERE/AUTO-tcx-remote-trust.sh" "$TW" "$TP" || echo "[remote-pair $P] WARN: trust step did not reach 'ready' — check tcx-stream"
remote_agent_cmd="$(timeout 15 "$HERE/../tcpuxdo" --op state 2>/dev/null \
    | jq -r --arg w "$TW" --arg p "$TP" '.state[$w].panes[$p].cmd // "missing"' 2>/dev/null)"
if [[ "$remote_agent_cmd" != claude ]]; then
    echo "[remote-pair $P] FAIL: remote agent pane $TW:$TP reports '${remote_agent_cmd:-unavailable}', expected claude"
fi
"$HERE/AUTO-create-or-reuse-remote-git-shell-pane-for-twin.sh" "$P" \
    || echo "[remote-pair $P] WARN: remote git shell pane not ready; rerun launcher after worker reconnects"
tmux select-window -t "$manager_window" || hold "could not select local manager window"

if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "=$LS"  # already inside tmux: switch the client
else
    tmux attach -t "=$LS" -c "$LD"   # terminal outside tmux: attach
fi
hold "detached from $LS (worker $W)"
