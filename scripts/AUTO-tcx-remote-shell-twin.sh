#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-shell-twin.sh [-n] [--check] <profile> — give a
#          remote-<profile> twin a SECOND pair, for plain bash commands:
#            remote: one bash pane on the worker, in the profile's dir
#                    (~/repos/<slug>), next to the claude pane — never inside it
#            local : window "shell" in tmux session remote-<profile> with
#                      sh-send   tcx-compose REPL: type a bash command, Enter
#                                runs it in the remote terminal
#                      sh-stream live view of that remote terminal
#          Both local panes are pinned to their own target group
#          TCX_GROUP=<session>-sh, so the claude pair (TCX_GROUP=<session>)
#          and the shell pair never steal each other's target.
#
# WHY:     2026-10-03, Bernardo: "in every remote- twin I want to send not only
#          prompts to the claude/codex agent but also bash commands to another
#          terminal". The claude pane must stay a claude pane; a second remote
#          terminal + its own local send/stream pair is the clean split.
#
# INPUTS:  <profile>  line in ~/.config/tcx-cockpit/profiles.conf
#          -n         print what would happen, change nothing
#          --check    after setup, type `echo SHELL-OK-<stamp> $(pwd)` into
#                     sh-send and wait for the OUTPUT line in sh-stream
#
# OUTPUTS: stdout "shell-twin<TAB>profile<TAB>OK|FAIL<TAB>detail"
#          group target ~/.cache/tcpuxdo/<session>-sh/target (worker<TAB>pane)
#          is the record of the remote terminal (reused on every re-run).
#          exit 0 ok · 1 failure · 3 relay unreachable · 64 usage
#
# REMOTE PANE: reused when the group target (or the clone's ops pane record
#          ~/runs/oss-clone/<profile>.pane) points at a live, idle shell;
#          otherwise create-window, and the new pane is found by diffing the
#          registry (the worker ignores a requested window index).
# RE-RUN SAFETY: idempotent — an existing "shell" window with sh-send/sh-stream
#          is left alone; nothing is created twice.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TCPUXDO="$REPO/tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
DRY=0; CHECK=0
while [[ "${1:-}" == -* ]]; do case "$1" in
    -n) DRY=1 ;; --check) CHECK=1 ;;
    *) echo "usage: AUTO-tcx-remote-shell-twin.sh [-n] [--check] <profile>" >&2; exit 64 ;;
esac; shift; done
P="${1:-}"; [[ -n "$P" ]] || { echo "usage: AUTO-tcx-remote-shell-twin.sh [-n] [--check] <profile>" >&2; exit 64; }
for c in jq tmux timeout comm; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 64; }; done

line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${P}:")" || { echo "no profile '$P'" >&2; exit 64; }
IFS=':' read -r _ W S D <<<"$line"
LS="remote-$P"; G="${S}-sh"
# Local project dir = cwd of every local pane of remote-<profile> (2026-10-03,
# Bernardo: panes must start in the project folder, not in tcpuxdo or ~/runs).
LD="$(awk -F'\t' -v p="$P" '$1==p{print $2; exit}' "${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}" 2>/dev/null)"
[[ -d "$LD" ]] || LD="$HOME"
GT="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/$G/target"
out(){ printf 'shell-twin\t%s\t%s\t%s\n' "$P" "$1" "$2"; [[ "$1" == OK ]]; }
tmux has-session -t "=$LS" 2>/dev/null || { out FAIL "no local session $LS — launch remote-$P first"; exit 64; }

# Build the local shell window first, so a worker outage does not leave the
# local twin with only its cockpit window.
pane_by_title(){ tmux list-panes -s -t "=$LS:" -F '#{pane_id}'$'\t''#{pane_title}' | awk -F'\t' -v t="$1" '$2==t{print $1}'; }
if [[ -z "$(pane_by_title sh-send)" ]]; then
    if (( DRY )); then echo "DRY tmux new-window -t =$LS: -n shell (sh-send | sh-stream)"
    else
        SEND="$(tmux new-window -d -t "=$LS:" -n shell -c "$LD" -P -F '#{pane_id}' \
            "TCX_GROUP=$G $HERE/AUTO-tcx-compose.sh; exec ${SHELL:-zsh}")" || { out FAIL "new-window failed"; exit 1; }
        tmux select-pane -t "$SEND" -T sh-send
        STREAM="$(tmux split-window -h -d -t "$SEND" -c "$LD" -P -F '#{pane_id}' \
            "TCX_GROUP=$G bash $REPO/setup/tcx-stream.sh")" || { out FAIL "split-window failed"; exit 1; }
        tmux select-pane -t "$STREAM" -T sh-stream
        tmux set-option -w -t "$SEND" automatic-rename off
        tmux set-option -p -t "$SEND" allow-set-title off 2>/dev/null || true
        tmux set-option -p -t "$STREAM" allow-set-title off 2>/dev/null || true
    fi
fi
if (( ! DRY )); then
    SEND="$(pane_by_title sh-send)"; STREAM="$(pane_by_title sh-stream)"
    [[ "$(grep -c . <<<"$SEND")" == 1 && "$(grep -c . <<<"$STREAM")" == 1 ]] \
        || { out FAIL "sh-send/sh-stream missing or duplicated in $LS"; exit 1; }
    SHELL_WINDOW="$(tmux display -p -t "$SEND" '#{window_id}')"
    if (( $(tmux list-panes -t "$SHELL_WINDOW" -F '#{pane_id}' | wc -l) < 3 )); then
        tmux split-window -v -d -t "$SEND" -c "$LD" \
            || { out FAIL "could not add local project shell pane"; exit 1; }
    fi
fi

panes_of_s(){ timeout 15 "$TCPUXDO" --op state 2>/dev/null \
    | jq -r --arg w "$W" --arg s "$S:" '.state[$w].panes | to_entries[] | select(.key|startswith($s)) | "\(.key)\t\(.value.cmd)\t\(.value.busy)"'; }
is_idle_shell(){ awk -F'\t' -v p="$1" '$1==p && $2 ~ /^(bash|zsh|sh)$/ && $3=="false"' <<<"$PANES" | grep -q .; }

# 1 — remote terminal
PANES="$(panes_of_s)" || true
[[ -n "$PANES" ]] || { out FAIL "relay state unreadable or no panes for $W:$S"; exit 3; }
RP=""
for cand in "$( [[ -s "$GT" ]] && cut -f2 "$GT")" "$(cat "$HOME/runs/oss-clone/$P.pane" 2>/dev/null)"; do
    [[ -n "$cand" ]] && is_idle_shell "$cand" && { RP="$cand"; break; }
done
if [[ -z "$RP" ]]; then
    if (( DRY )); then echo "DRY create-window on $W:$S, then cd $D"; RP="$S:?:0"
    else
        before="$(cut -f1 <<<"$PANES" | sort)"
        timeout 30 "$TCPUXDO" --op create-window --worker "$W" --session "$S" --window 9 >/dev/null 2>&1
        for _ in $(seq 1 20); do
            sleep 3
            RP="$(comm -13 <(echo "$before") <(panes_of_s | cut -f1 | sort) | head -1)"
            [[ -n "$RP" ]] && break
        done
        [[ -n "$RP" ]] || { out FAIL "create-window produced no new pane"; exit 1; }
        sleep 2
    fi
fi
if (( ! DRY )); then
    timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$RP" \
        -c "mkdir -p $D && cd $D && tmux select-pane -T command-shell; clear" >/dev/null 2>&1 \
        || { out FAIL "cd into $D not accepted on $RP"; exit 1; }
fi

# 2 — pin the shell group target (tcx.sh's own writer)
if (( DRY )); then echo "DRY TCX_GROUP=$G tcx.sh use $W $RP"
else TCX_GROUP="$G" "$REPO/tcx.sh" use "$W" "$RP" >/dev/null || { out FAIL "tcx.sh use failed"; exit 1; }; fi

# 3 — local window was built before touching the relay.
(( DRY )) && { out OK "dry run"; exit 0; }

# 4 — optional round trip: command typed in sh-send, OUTPUT line seen in sh-stream
if (( CHECK )); then
    TOK="SHELL-OK-$P-$(date +%H%M%S)"
    sleep 3
    tmux send-keys -t "$SEND" -l "echo $TOK \$(pwd)"; sleep 0.3; tmux send-keys -t "$SEND" Enter
    for _ in $(seq 1 25); do
        tmux capture-pane -p -t "$STREAM" -J | grep -qE "^$TOK /" && \
            { out OK "$W $RP ← $LS:shell; round trip: $(tmux capture-pane -p -t "$STREAM" -J | grep -E "^$TOK /" | tail -1)"; exit 0; }
        sleep 2
    done
    out FAIL "no '$TOK <pwd>' output line in sh-stream within 50s"; exit 1
fi
out OK "$W $RP ← $LS:shell (sh-send $SEND, sh-stream $STREAM)"
