#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-claude-restart.sh <profile> — restart the REMOTE
#          claude of a remote pair in --dangerously-skip-permissions mode,
#          keeping its conversation (claude --continue), entirely from m1.
#            1. Esc   (cancel a pending tool-permission dialog, if any)
#            2. /exit (claude quits back to the worker pane's shell)
#            3. wait until the relay reports the pane's foreground is a shell
#            4. send the launch line: cd <dir> && exec claude <flags> --continue
#            5. AUTO-tcx-remote-trust.sh answers the trust / bypass dialogs
#
# WHY:     2026-10-02: the first remote pairs launched plain `claude`, so the
#          remote agent stopped on "Do you want to proceed?" for every tool —
#          a remote agent that blocks on a dialog nobody watches is a failed
#          setup (Bernardo). New pairs start in skip-permissions mode
#          (AUTO-tcx-remote-pair-window.sh); this converts one already running.
#
# INPUTS:  <profile>   line in ${TCX_COCKPIT_PROFILES_FILE:-~/.config/tcx-cockpit/profiles.conf}
#          --fresh     start a NEW conversation (no --continue)
#          -n          dry run: print every tcpuxdo argv, send nothing
#          env TCX_RESTART_CLAUDE_CMD (default "claude --dangerously-skip-permissions")
#
# OUTPUTS: stdout: "restart<TAB><profile><TAB>OK|FAIL<TAB>detail"; the trust line.
#          exit 0 ok · 1 failure · 3 relay unreachable · 64 usage
#
# PANE: resolved from the pair's group target ~/.cache/tcpuxdo/<session>/target
#          (written by the window program through tcx.sh use) — never typed.
# RE-RUN SAFETY: safe to repeat; each run restarts claude once and continues
#          the same conversation. It types ONLY into the pair's own remote pane.
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
CMD="${TCX_RESTART_CLAUDE_CMD:-claude --dangerously-skip-permissions}"
CONT=" --continue"; DRY=0
while [[ "${1:-}" == -* ]]; do case "$1" in
    --fresh) CONT="" ;; -n) DRY=1 ;;
    *) echo "usage: AUTO-tcx-remote-claude-restart.sh [--fresh] [-n] <profile>" >&2; exit 64 ;;
esac; shift; done
P="${1:-}"; [[ -n "$P" ]] || { echo "usage: AUTO-tcx-remote-claude-restart.sh [--fresh] [-n] <profile>" >&2; exit 64; }
PROMPT=""
INSTRUCTION_SETUP=""
instruction_file="/home/b/p/all-my-tiny-projects/claude-rules/instructions/$P-remote-worker.md"
[[ -s "$instruction_file" ]] || instruction_file="/home/b/p/all-my-tiny-projects/claude-rules/instructions/remote-twin-remote-worker.md"
[[ -s "$instruction_file" ]] || { echo "remote instruction .md missing: $instruction_file" >&2; exit 1; }
command -v base64 >/dev/null || { echo "base64 is needed to copy the instruction .md to the worker" >&2; exit 64; }
payload="$(base64 -w0 "$instruction_file")" || { echo "could not read $instruction_file" >&2; exit 1; }
instruction_target="/tmp/tcpuxdo-$P-remote-worker.md"
INSTRUCTION_SETUP="printf %s $payload | base64 -d > $instruction_target && "
PROMPT=" \"Read $instruction_target and follow it. Report if you cannot read it.\""
for c in jq timeout; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 64; }; done

line="$(grep -v '^[[:space:]]*#' "$CONF" | grep -m1 "^${P}:")" || { echo "no profile '$P' in $CONF" >&2; exit 64; }
IFS=':' read -r _ _ S D <<<"$line"
GT="${XDG_CACHE_HOME:-$HOME/.cache}/tcpuxdo/$S/target"
[[ -s "$GT" ]] || { echo "no group target $GT — launch the pair first" >&2; exit 64; }
IFS=$'\t' read -r W PANE < "$GT"

verdict(){ printf 'restart\t%s\t%s\t%s\n' "$P" "$1" "$2"; [[ "$1" == OK ]]; exit $?; }
send(){  # $1 = literal text; tcpuxdo appends Enter
    if (( DRY )); then printf 'DRY %q -w %q -p %q -c %q\n' "$TCPUXDO" "$W" "$PANE" "$1"; return 0; fi
    "$TCPUXDO" -w "$W" -p "$PANE" -c "$1" >/dev/null 2>&1
}
fg_cmd(){ timeout 15 "$TCPUXDO" --op state 2>/dev/null \
    | jq -r --arg w "$W" --arg p "$PANE" '.state[$w].panes[$p].cmd // "?"'; }

LAUNCH="bash -lc 'export PATH=\"\$HOME/.local/bin:\$PATH\"; cd ${D} && ${INSTRUCTION_SETUP}exec ${CMD}${CONT}${PROMPT}'"

send $'\e' || verdict FAIL "Esc not queued (relay?)"
sleep 2
send "/exit" || verdict FAIL "/exit not queued"
if (( DRY )); then send "$LAUNCH"; verdict OK "dry run"; fi

for _ in $(seq 1 20); do
    c="$(fg_cmd)"; [[ "$c" =~ ^(bash|zsh|sh|fish)$ ]] && break; sleep 2
done
[[ "$c" =~ ^(bash|zsh|sh|fish)$ ]] || verdict FAIL "claude did not exit (pane foreground: $c)"

send "$LAUNCH" || verdict FAIL "launch line not queued"
"$HERE/AUTO-tcx-remote-trust.sh" "$W" "$PANE" || verdict FAIL "claude did not reach its input box"
verdict OK "$W $PANE runs: ${CMD}${CONT}${PROMPT}"
