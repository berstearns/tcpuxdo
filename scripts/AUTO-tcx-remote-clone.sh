#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-clone.sh [-n] <profile> — make the REMOTE side of a
#          remote-<profile> twin hold its GitHub repo on the worker's disk:
#            1. clone <owner/repo> branch oss/public-autofill into ~/repos/<slug>
#               on the worker (skip when ~/repos/<slug>/.git already exists)
#            2. fetch every unpushed agent commit left in the worker's run roots
#               (~/runs/<slug>-*/repo, branch oss/public-autofill) as
#               refs/remotes/runroot/<run-root> — no work is lost
#            3. rewrite the profile's dir to ~/repos/<slug> (so every relaunch
#               starts claude IN the repo)
#          All remote work runs in its OWN window <session>:9 (pane
#          <session>:9:0) of the pair's remote session, never in the claude pane.
#
# WHY:     2026-10-03, Bernardo: "none of the remote- targets hold the github
#          repo on their local disk". The pairs launched claude in ~ and the
#          agents cloned into throw-away run roots; nothing stable existed on
#          do-app11 for the human to open. The remote commands are a fixed
#          template in this tracked file — never retyped.
#
# INPUTS:  <profile>  line in ~/.config/tcx-cockpit/profiles.conf AND in
#                     ~/.config/tcx-cockpit/oss-plan.tsv (gives the slug); the
#                     repo URL comes from ~/runs/oss-prep/<slug>.status (READY)
#          -n         print the remote command + every tcpuxdo argv, run nothing
#
# OUTPUTS: stdout "clone<TAB>profile<TAB>OK|FAIL<TAB>detail" (detail = remote
#          HEAD line, or the captured error). Receipt with the full remote pane
#          capture: ~/runs/oss-clone/<profile>-<stamp>.log
#          profiles.conf: the profile's dir field → ~/repos/<slug> (atomic rewrite,
#          this script is that field's only writer after a clone).
#          exit 0 ok · 1 remote failure · 3 relay unreachable · 64 usage
#
# RE-RUN SAFETY: idempotent — an existing clone is fetched, not re-cloned; the
#          profile rewrite is a no-op when already ~/repos/<slug>.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
PLAN="${OSS_PLAN:-$HOME/.config/tcx-cockpit/oss-plan.tsv}"
BRANCH="${OSS_SEED_BRANCH:-oss/public-autofill}"
WIN=9
# ~/p is root-owned on do-app11 (2026-10-03: Permission denied) → ~/repos
RBASE="${TCX_REMOTE_REPO_BASE:-repos}"
DRY=0; [[ "${1:-}" == "-n" ]] && { DRY=1; shift; }
P="${1:-}"; [[ -n "$P" ]] || { echo "usage: AUTO-tcx-remote-clone.sh [-n] <profile>" >&2; exit 64; }
for c in jq timeout; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 64; }; done

line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${P}:")" || { echo "no profile '$P' in $CONF" >&2; exit 64; }
IFS=':' read -r _ W S _ <<<"$line"
SLUG="$(awk -F'\t' -v p="$P" '$1==p{print $2; exit}' "$PLAN")"
[[ -n "$SLUG" ]] || { echo "no '$P' line in $PLAN" >&2; exit 64; }
ST="$HOME/runs/oss-prep/$SLUG.status"
grep -q '^READY' "$ST" 2>/dev/null || { echo "$SLUG is not READY ($ST)" >&2; exit 64; }
URL="$(cut -f2 "$ST")"; REPO="${URL#https://github.com/}"; REPO="${REPO%.git}"

LOGD="$HOME/runs/oss-clone"; mkdir -p "$LOGD"; LOG="$LOGD/$P-$(date +%Y%m%dT%H%M%S).log"
out(){ printf 'clone\t%s\t%s\t%s\n' "$P" "$1" "$2" | tee -a "$LOG"; [[ "$1" == OK ]]; }
MARK="TCXCLONE$$"
PANE="(resolved below)"

# GIT_TERMINAL_PROMPT=0: git must FAIL, never ask "Username for github.com" —
# a prompt makes the pane busy and the worker then refuses every later key
# (2026-10-03, linkedin:2:0 stuck that way). `gh auth setup-git` makes plain
# git (fetch/push, also the agents' pushes) use gh's stored login.
# The remote command: ONE line (tcpuxdo types it literally + Enter). Prints
# "<MARK>_RC=<n>" last so the capture can tell done from still-running.
RCMD="export GIT_TERMINAL_PROMPT=0; gh auth setup-git -h github.com; D=\$HOME/$RBASE/$SLUG; mkdir -p \$HOME/$RBASE; if [ ! -d \$D/.git ]; then gh repo clone $REPO \$D -- -b $BRANCH || git clone -b $BRANCH https://github.com/$REPO.git \$D; fi; cd \$D && git fetch -q origin; rc=\$?; for r in \$HOME/runs/$SLUG-*/repo; do [ -d \$r/.git ] && git -C \$r rev-parse -q --verify $BRANCH >/dev/null && git fetch -q \$r $BRANCH:refs/remotes/runroot/\$(basename \$(dirname \$r)); done; echo HEAD \$(git -C \$D log --oneline -1) RUNROOTS \$(git -C \$D branch -r --list 'runroot/*' | wc -l); echo ${MARK}_RC=\$rc"

if (( DRY )); then
    printf 'DRY %q --op create-window --worker %q --session %q --window %q\n' "$TCPUXDO" "$W" "$S" "$WIN"
    printf 'DRY %q -w %q -p %q -c %q\n' "$TCPUXDO" "$W" "$PANE" "$RCMD"
    echo "DRY profiles.conf: $P dir → ~/$RBASE/$SLUG"; exit 0
fi

# 1 — the ops pane. The worker ignores the requested window index (tmux takes
#     the next free one), so the new pane is found by DIFFING the registry's
#     pane set for <session> before/after, and remembered in a record file so a
#     re-run reuses it instead of opening another window.
REC="$LOGD/$P.pane"
panes_of_s(){ timeout 15 "$TCPUXDO" --op state 2>/dev/null \
    | jq -r --arg w "$W" --arg s "$S:" '.state[$w].panes | to_entries[] | select(.key|startswith($s)) | "\(.key)\t\(.value.cmd)"'; }
PANE=""
if [[ -s "$REC" ]]; then
    old="$(cat "$REC")"
    panes_of_s | awk -F'\t' -v p="$old" '$1==p && $2 ~ /^(bash|zsh|sh)$/' | grep -q . && PANE="$old"
fi
if [[ -z "$PANE" ]]; then
    before="$(panes_of_s | cut -f1 | sort)"
    timeout 30 "$TCPUXDO" --op create-window --worker "$W" --session "$S" --window "$WIN" >>"$LOG" 2>&1
    for _ in $(seq 1 20); do
        sleep 3
        new="$(comm -13 <(echo "$before") <(panes_of_s | cut -f1 | sort) | head -1)"
        [[ -n "$new" ]] && { PANE="$new"; break; }
    done
    [[ -n "$PANE" ]] || { out FAIL "create-window on $W:$S produced no new pane in the registry"; exit 1; }
    echo "$PANE" > "$REC"
fi
echo "ops pane: $PANE" >> "$LOG"
# 2 — run the template once, poll the capture for the sentinel
timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$PANE" -c "$RCMD" >>"$LOG" 2>&1 \
    || { out FAIL "send-keys to $PANE not accepted (relay or busy pane, see $LOG)"; exit 3; }
cap=""
for _ in $(seq 1 30); do
    sleep 5
    cap="$(timeout 40 "$TCPUXDO" read -w "$W" -p "$PANE" --lines 60 2>/dev/null)" || continue
    grep -q "${MARK}_RC=" <<<"$cap" && break
done
printf '%s\n' "$cap" >> "$LOG"
rc="$(grep -o "${MARK}_RC=[0-9]*" <<<"$cap" | tail -1 | cut -d= -f2)"
head_line="$(grep -o 'HEAD .*' <<<"$cap" | grep -v 'git log' | tail -1)"
[[ "$rc" == 0 && -n "$head_line" ]] || { out FAIL "remote clone did not finish clean (rc=${rc:-none}); last lines: $(grep -v '^\s*$' <<<"$cap" | tail -3 | tr '\n' ' ')"; exit 1; }

# 3 — profile dir → ~/repos/<slug> (atomic rewrite of the one line)
tmp="$(mktemp "$CONF.XXXXXX")"
awk -F: -v OFS=: -v p="$P" -v d="~/$RBASE/$SLUG" '!/^[[:space:]]*#/ && $1==p {$4=d} {print}' "$CONF" > "$tmp" && mv -f "$tmp" "$CONF"
out OK "$W:~/$RBASE/$SLUG  $head_line"
