#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-status.sh — ONE table: which remote-<profile> twins
#          work right now. Read-only: one relay `state` call + local tmux reads.
#          Columns:
#            profile   worker(age)   remote-claude   remote-shell   local-session
#            agent-mode   repo(remote dir)   VERDICT
#          VERDICT = OK only when: worker live (< TCX_STATUS_DEAD_SECS), the
#          remote claude pane exists and runs claude, the local session
#          remote-<profile> has tcx-send/tcx-stream, and the stream shows
#          "bypass permissions on". Otherwise the FIRST broken thing is named.
#
# WHY:     2026-10-03, Bernardo: "I don't know which remote- ones work". Nine
#          launchers, three workers, two pairs per twin — the answer must be one
#          command, not a tour of panes.
#
# INPUTS:  env TCX_STATUS_DEAD_SECS (default 180) · TCX_COCKPIT_PROFILES_FILE
# OUTPUTS: the table on stdout (TSV when piped). exit 0 all OK · 1 any not OK
#          · 3 relay unreachable (every row then says "relay?").
#===============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
DEAD="${TCX_STATUS_DEAD_SECS:-180}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo"

STATE="$(timeout 60 "$TCPUXDO" --op state 2>/dev/null)"
jq -e .state >/dev/null 2>&1 <<<"$STATE" || STATE=""
rc=0; [[ -z "$STATE" ]] && rc=3

rows=()
while IFS=':' read -r P W S D; do
    [[ -z "$P" || "$P" == \#* ]] && continue
    LS="remote-$P"; v=""
    # worker
    if [[ -z "$STATE" ]]; then wk="relay?"; v="${v:-relay unreachable}"
    else
        age="$(jq -r --arg w "$W" '(.state[$w].last_update // 0) as $t | if $t==0 then "none" else ((now-$t)|floor|tostring) end' <<<"$STATE")"
        if [[ "$age" == none ]]; then wk="$W(unknown)"; v="${v:-worker $W not registered}"
        elif (( age > DEAD )); then wk="$W(${age}s)"; v="${v:-worker $W DEAD ${age}s}"
        else wk="$W(${age}s)"; fi
    fi
    # remote claude pane (from the pair's group target, else <session>:0:0)
    cp="$(cut -f2 "$CACHE/$S/target" 2>/dev/null)"; cp="${cp:-$S:0:0}"
    if [[ -n "$STATE" ]]; then
        cc="$(jq -r --arg w "$W" --arg p "$cp" '.state[$w].panes[$p].cmd // "missing"' <<<"$STATE")"
        rcl="$cp=$cc"; [[ "$cc" == claude ]] || v="${v:-remote claude pane $cp is $cc}"
        sp="$(cut -f2 "$CACHE/$S-sh/target" 2>/dev/null)"
        if [[ -n "$sp" ]]; then sc="$(jq -r --arg w "$W" --arg p "$sp" '.state[$w].panes[$p].cmd // "missing"' <<<"$STATE")"; rsh="$sp=$sc"
        else rsh="none"; fi
    else rcl="?"; rsh="?"; fi
    # local session + mode seen in the local stream pane
    if tmux has-session -t "=$LS" 2>/dev/null; then
        titles="$(tmux list-panes -s -t "=$LS:" -F '#{pane_title}' | sort -u | tr '\n' ' ')"
        loc="yes"; [[ "$titles" == *sh-send* ]] && loc="yes+shell"
        [[ "$titles" == *tcx-send* && "$titles" == *tcx-stream* ]] || v="${v:-local $LS lacks tcx-send/tcx-stream}"
        st="$(tmux list-panes -s -t "=$LS:" -F '#{pane_id} #{pane_title}' | awk '$2=="tcx-stream"{print $1; exit}')"
        if [[ -n "$st" ]] && tmux capture-pane -p -t "$st" -J | grep -q 'bypass permissions on'; then mode=bypass
        elif [[ -n "$st" ]]; then mode="manual?"; v="${v:-agent not in bypass mode}"
        else mode="?"; fi
    else loc="no"; mode="-"; v="${v:-local session $LS not open (launch remote-$P)}"; fi
    [[ -z "$v" ]] && v=OK || rc=$(( rc == 3 ? 3 : 1 ))
    rows+=("$P"$'\t'"$wk"$'\t'"$rcl"$'\t'"$rsh"$'\t'"$loc"$'\t'"$mode"$'\t'"$D"$'\t'"$v")
done < "$CONF"

{
    printf 'profile\tworker(age)\tremote-claude\tremote-shell\tlocal\tmode\tremote-dir\tVERDICT\n'
    printf '%s\n' "${rows[@]}"
} | if [[ -t 1 ]]; then column -t -s $'\t'; else cat; fi
exit $rc
