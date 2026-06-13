#!/usr/bin/env bash
#===============================================================================
# watchdog.sh — lightweight tcpuxdo node liveness monitor.
#
# Checks every CHECK_INTERVAL seconds whether worker.py is running inside the
# tcpuxdo-worker tmux session. If the session is gone or worker.py is not the
# active process, runs node-up.sh to respawn it.
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
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-15}"
LOG="${WATCHDOG_LOG:-$HOME/tcpuxdo-watchdog.log}"

log() { echo "[watchdog $(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

log "start — monitoring $SESSION every ${CHECK_INTERVAL}s (log: $LOG)"

while true; do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        log "ALERT: session $SESSION missing — running node-up.sh"
        bash "$ROOT/setup/node-up.sh" >> "$LOG" 2>&1 \
            && log "node-up.sh OK" \
            || log "node-up.sh FAILED (exit $?)"
    elif ! pgrep -f "worker\.py" > /dev/null 2>&1; then
        log "ALERT: worker.py not running — running worker-restart.sh"
        bash "$ROOT/setup/worker-restart.sh" >> "$LOG" 2>&1 \
            && log "worker-restart.sh OK" \
            || log "worker-restart.sh FAILED (exit $?)"
    fi
    sleep "$CHECK_INTERVAL"
done
