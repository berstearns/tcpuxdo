#!/usr/bin/env bash
# Create one dedicated, idle git shell window in the worker's twin session.
# The recorded pane ID makes repeated launches reuse it without duplicates.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
P="${1:-}"
[[ "$#" -eq 1 && "$P" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "usage: $(basename "$0") <profile>" >&2; exit 64;
}
line="$(awk -F: -v p="$P" '$1==p {print; exit}' "$CONF")"
[[ -n "$line" ]] || { echo "no profile '$P' in $CONF" >&2; exit 64; }
IFS=: read -r _ W S D <<<"$line"
[[ "$D" =~ ^[A-Za-z0-9_.~/+-]+$ ]] || { echo "unsafe remote directory in profile '$P'" >&2; exit 64; }

RECORD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/remote-git-panes"
RECORD="$RECORD_DIR/$P.tsv"
state(){ timeout 15 "$TCPUXDO" --op state; }
panes(){ jq -r --arg w "$W" --arg s "$S:" '.state[$w].panes // {} | to_entries[] | select(.key|startswith($s)) | [.key,.value.cmd,(.value.busy|tostring)] | @tsv'; }

before="$(state | panes)" || { echo "cannot read relay state for $W" >&2; exit 3; }
pane=""
needs_setup=0
if [[ -s "$RECORD" ]]; then
    IFS=$'\t' read -r recorded_worker recorded_pane recorded_ready < "$RECORD"
    if [[ "$recorded_worker" == "$W" ]] && awk -F'\t' -v p="$recorded_pane" \
        '$1==p {found=1} END {exit !found}' <<<"$before"; then
        pane="$recorded_pane"
        [[ "${recorded_ready:-}" == ready ]] || needs_setup=1
    fi
fi

if [[ -z "$pane" ]]; then
    old_ids="$(cut -f1 <<<"$before" | sort)"
    timeout 30 "$TCPUXDO" --op create-window --worker "$W" --session "$S" --window 9 >/dev/null \
        || { echo "could not create remote git window on $W:$S" >&2; exit 1; }
    for _ in $(seq 1 20); do
        sleep 2
        current="$(state | panes)" || continue
        pane="$(comm -13 <(printf '%s\n' "$old_ids") <(cut -f1 <<<"$current" | sort) | head -1)"
        [[ -n "$pane" ]] && break
    done
    [[ -n "$pane" ]] || { echo "remote git pane did not register on $W:$S" >&2; exit 1; }
    mkdir -p "$RECORD_DIR"
    printf '%s\t%s\tpending\n' "$W" "$pane" > "$RECORD"
    needs_setup=1
fi

if (( needs_setup )); then
    current="$(state | panes)" || { echo "cannot inspect remote git pane $W:$pane" >&2; exit 3; }
    awk -F'\t' -v p="$pane" \
        '$1==p && $2 ~ /^(bash|zsh|sh)$/ && $3=="false" {found=1} END {exit !found}' <<<"$current" \
        || { echo "remote git pane $W:$pane is busy; retry after it is idle" >&2; exit 1; }
    timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$pane" \
        -c "mkdir -p $D && cd $D && export GIT_TERMINAL_PROMPT=0 && tmux select-pane -T git-shell" >/dev/null \
        || { echo "could not enter project directory in remote git pane $W:$pane" >&2; exit 1; }
    printf '%s\t%s\tready\n' "$W" "$pane" > "$RECORD"
fi
printf 'remote-git\t%s\t%s\t%s\n' "$P" "$W" "$pane"
