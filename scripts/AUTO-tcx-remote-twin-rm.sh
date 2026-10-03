#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-twin-rm.sh [-n] [--rmdir] <name> — remove a remote
#          twin on BOTH sides (the undo of AUTO-tcx-remote-twin-new.sh):
#            LOCAL : close the i3 window (class i3minator-remote-<name>), kill
#                    tmux session remote-<name>, delete remote-<name>.yml, drop
#                    the <name> lines from profiles.conf and local-dirs.tsv
#                    (atomic rewrite), drop its tcpuxdo target caches
#            REMOTE: end tmux session <session> on the worker by exiting each of
#                    its panes (tcpuxdo has no kill-session op): claude panes
#                    get "/exit", shell panes get "exit"; then the registry is
#                    re-read to confirm the session is gone
#          The project dirs (here and on the worker) are KEPT — your files are
#          never deleted. --rmdir removes the LOCAL dir only if it is empty.
#
# WHY:     2026-10-03, Bernardo created rag-papers-gcp with a wrong remote dir
#          (~/p is not writable on do-app11) and asked "how can I kill both?".
#
# INPUTS:  <name>   the twin (profile) name
#          -n       print every step, change nothing
#          --rmdir  also rmdir the local project dir when it is empty
# OUTPUTS: one line per step "twin-rm<TAB>name<TAB>step<TAB>result"
#          exit 0 everything removed · 1 something left (named) · 64 usage
# RE-RUN SAFETY: idempotent — a part already gone is reported "absent".
#          A busy remote pane (running a command) is NOT interrupted: it is
#          reported, and the session stays until that command ends.
#===============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
DIRS="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
I3D="${I3MINATOR_DIR:-$HOME/.config/i3minator}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo"
DRY=0; RMDIR=0
while [[ "${1:-}" == -* ]]; do case "$1" in
    -n) DRY=1 ;; --rmdir) RMDIR=1 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: AUTO-tcx-remote-twin-rm.sh [-n] [--rmdir] <name>" >&2; exit 64 ;;
esac; shift; done
N="${1:-}"; [[ "$N" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: AUTO-tcx-remote-twin-rm.sh [-n] [--rmdir] <name>" >&2; exit 64; }
rc=0
say(){ printf 'twin-rm\t%s\t%s\t%s\n' "$N" "$1" "$2"; }
do_(){ if (( DRY )); then printf 'DRY'; printf ' %q' "$@"; echo; else "$@"; fi; }

line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${N}:" || true)"
IFS=':' read -r _ W S _ <<<"$line"; S="${S:-$N}"
LD="$(awk -F'\t' -v p="$N" '$1==p{print $2; exit}' "$DIRS" 2>/dev/null)"

# ── REMOTE first (needs the profile to know worker + session) ──────────────
if [[ -n "${W:-}" ]]; then
    STATE="$(timeout 60 "$TCPUXDO" --op state 2>/dev/null)"
    mapfile -t panes < <(jq -r --arg w "$W" --arg s "$S:" '.state[$w].panes // {} | to_entries[] | select(.key|startswith($s)) | "\(.key)\t\(.value.cmd)\t\(.value.busy)"' <<<"$STATE" 2>/dev/null)
    if (( ${#panes[@]} == 0 )); then say remote-session "absent ($W:$S)"
    else
        for row in "${panes[@]}"; do
            IFS=$'\t' read -r p c b <<<"$row"
            if [[ "$b" == true ]]; then say "remote $p" "BUSY ($c) — left running"; rc=1; continue; fi
            case "$c" in
                claude) do_ timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$p" -c "/exit" >/dev/null 2>&1; sleep 4
                        do_ timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$p" -c "exit" >/dev/null 2>&1 ;;
                *)      do_ timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$p" -c "exit" >/dev/null 2>&1 ;;
            esac
            say "remote $p" "sent exit ($c)"
        done
        if (( ! DRY )); then
            gone=0
            for _ in $(seq 1 10); do
                sleep 3
                left="$(timeout 15 "$TCPUXDO" --op state 2>/dev/null | jq -r --arg w "$W" --arg s "$S:" '[.state[$w].panes // {} | keys[] | select(startswith($s))] | length')"
                [[ "$left" == 0 ]] && { gone=1; break; }
            done
            if (( gone )); then say remote-session "gone ($W:$S)"; else say remote-session "STILL THERE ($W:$S, ${left:-?} pane(s))"; rc=1; fi
        fi
    fi
else
    say remote-session "unknown (no profile line for $N)"
fi

# ── LOCAL ──────────────────────────────────────────────────────────────────
do_ i3-msg "[class=\"^i3minator-remote-${N}\$\"] kill" >/dev/null 2>&1 && say i3-window "closed (if open)"
if tmux has-session -t "=remote-$N" 2>/dev/null; then do_ tmux kill-session -t "=remote-$N"; say local-session "killed remote-$N"
else say local-session "absent"; fi
if [[ -e "$I3D/remote-$N.yml" ]]; then do_ rm -f "$I3D/remote-$N.yml"; say i3minator-yml "removed"; else say i3minator-yml "absent"; fi
for f in "$CONF" "$DIRS"; do
    if [[ "$f" == "$CONF" ]]; then hit="$(grep -c "^${N}:" "$f")"; else hit="$(awk -F'\t' -v p="$N" '$1==p' "$f" | grep -c .)"; fi
    if (( hit == 0 )); then say "$(basename "$f")" "absent"; continue; fi
    if (( DRY )); then say "$(basename "$f")" "would drop $hit line(s)"; continue; fi
    tmp="$(mktemp "$f.XXXXXX")"
    if [[ "$f" == "$CONF" ]]; then grep -v "^${N}:" "$f" > "$tmp"; else awk -F'\t' -v p="$N" '$1!=p' "$f" > "$tmp"; fi
    mv -f "$tmp" "$f"; say "$(basename "$f")" "dropped $hit line(s)"
done
for d in "$CACHE/$S" "$CACHE/$S-sh"; do [[ -d "$d" ]] && { do_ rm -rf "$d"; say cache "removed $d"; }; done
if (( RMDIR )) && [[ -n "$LD" && -d "$LD" ]]; then
    if (( DRY )); then say local-dir "would rmdir $LD (only if empty)"
    elif rmdir "$LD" 2>/dev/null; then say local-dir "removed empty $LD"
    else say local-dir "kept $LD (not empty)"; fi
else
    say local-dir "kept ${LD:-?} (files are never deleted)"
fi
exit $rc
