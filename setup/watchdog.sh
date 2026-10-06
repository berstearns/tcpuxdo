#!/usr/bin/env bash
#===============================================================================
# watchdog.sh — lightweight tcpuxdo node liveness monitor.
#
# Checks every CHECK_INTERVAL seconds whether the uniquely titled worker pane
# is alive. It remains in a separate pane and never restarts itself.
#
# Run this in a DEDICATED tmux session so it survives OOM or Claude Code crashes:
#   tmux new-session -d -s tcpuxdo-watchdog -c ~/tcpuxdo 'bash setup/watchdog.sh'
#
# Or one-shot inline (for testing):
#   bash setup/watchdog.sh
#===============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$ROOT"

SESSION="${WORKER_SESSION:-tcpuxdo-worker}"
WINDOW="${WORKER_WINDOW:-worker}"
PANE_TITLE="${WORKER_PANE_MAIN:-tcpuxdo-worker-main}"
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-15}"
LOG="${WATCHDOG_LOG:-$HOME/tcpuxdo-watchdog.log}"

log() { echo "[watchdog $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

log "start — monitoring $SESSION every ${CHECK_INTERVAL}s (log: $LOG)"

while true; do
    mapfile -t panes < <(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_id} #{pane_title} #{pane_current_command}' 2>/dev/null | awk -v t="$PANE_TITLE" '$2==t {print $1}')
    if (( ${#panes[@]} != 1 )); then
        log "ERROR: expected exactly one pane titled $PANE_TITLE; found ${#panes[@]}"
    elif ! tmux display-message -p -t "${panes[0]}" '#{pane_current_command}' | grep -Eq 'python(3)?'; then
        log "ALERT: worker pane is not running python — running worker-restart.sh"
        bash "$ROOT/setup/worker-restart.sh" >> "$LOG" 2>&1 \
            && log "worker-restart.sh OK" \
            || log "worker-restart.sh FAILED (exit $?)"
    fi
    sleep "$CHECK_INTERVAL"
done
