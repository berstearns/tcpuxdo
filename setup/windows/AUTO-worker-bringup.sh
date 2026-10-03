#!/usr/bin/env bash
# WHAT:    Ensure the tcpuxdo worker on THIS WSL box is up and talking to the
#          relay, idempotently, and print ONE machine-readable result line
#          (BRINGUP_RESULT=<code>) plus a human message the double-click popup
#          shows the girlfriend.
# WHY:     When the worker dies, only something running ON the node can restart
#          it (tcpuxdo never pushes to nodes over the network). This is the
#          logic behind the Desktop button Reconnect-Worker.vbs — kept as a
#          tracked program so the .vbs stays a thin, secret-free shim.
# INPUTS:  --status   check only; never start/restart the worker
#          --quiet    suppress the human lines on stderr (keep the result line)
#          env TCPUXDO_DIR   repo path (default: $HOME/tcpuxdo)
# OUTPUTS: stderr: human ✓/✗ lines. stdout LAST line: BRINGUP_RESULT=<code>
#          plus BRINGUP_MSG=<one-line text for the popup>.
#          codes: 0 connected · 10 started, waiting to register ·
#                 20 relay unreachable/rejected · 30 repo/.env missing ·
#                 40 python3/tmux missing · 50 could not start the worker
# USAGE (combinatorial):
#   bash setup/windows/AUTO-worker-bringup.sh            # the button's path
#   bash setup/windows/AUTO-worker-bringup.sh --status   # is it up? touch nothing
#   TCPUXDO_DIR=/opt/tcpuxdo bash …/AUTO-worker-bringup.sh   # non-default checkout
#   bash setup/windows/AUTO-worker-bringup.sh --status --quiet   # for a heartbeat
# RE-RUN SAFETY: idempotent — a healthy, already-registered worker is left
#          untouched; only a missing/stale one is (re)started.
set -uo pipefail

STATUS_ONLY=0; QUIET=0
for a in "$@"; do case "$a" in
  --status) STATUS_ONLY=1 ;;
  --quiet)  QUIET=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 40 ;;
esac; done

REPO="${TCPUXDO_DIR:-$HOME/tcpuxdo}"
say()  { [ "$QUIET" -eq 1 ] || printf '  %s\n' "$*" >&2; }
done_() { printf 'BRINGUP_RESULT=%s\nBRINGUP_MSG=%s\n' "$1" "$2"; exit "$1"; }

command -v python3 >/dev/null || done_ 40 "Setup problem: python3 missing in WSL. Call Bernardo."
command -v tmux    >/dev/null || done_ 40 "Setup problem: tmux missing in WSL. Call Bernardo."
[ -d "$REPO" ]      || done_ 30 "Setup problem: $REPO not found. Call Bernardo."
[ -f "$REPO/.env" ] || done_ 30 "Setup problem: $REPO/.env missing. Call Bernardo."
cd "$REPO" || done_ 30 "Setup problem: cannot enter $REPO. Call Bernardo."

set -a
# shellcheck disable=SC1091 # Node-specific, git-ignored config.
. ./.env
set +a
NAME="${TCPUX_WORKER:-$(hostname)}"
: "${TCPUX_HOST:?}" "${TCPUX_PORT:?}" 2>/dev/null || done_ 30 "Setup problem: .env has no relay host/port. Call Bernardo."

# worker_age NAME -> prints the worker's seconds-since-last-report, or "down"
# (relay unreachable), "rejected:CODE", or "never" (not in registry). ONE relay
# round-trip; the same proto the rest of the fleet uses.
worker_age() {
  PYTHONPATH="$REPO" TCPX_H="$TCPUX_HOST" TCPX_P="$TCPUX_PORT" TCPX_N="$NAME" python3 - <<'PY'
import os, sys, time, socket
socket.setdefaulttimeout(6)
try:
    from proto import rpc
    r = rpc(os.environ["TCPX_H"], int(os.environ["TCPX_P"]), {"op": "state"})
except Exception as e:
    print("down:" + type(e).__name__); sys.exit(0)
if not r.get("ok"):
    print("rejected:" + str(r.get("err_code", "UNKNOWN"))); sys.exit(0)
rec = r.get("state", {}).get(os.environ["TCPX_N"])
if not rec or not rec.get("last_update"):
    print("never"); sys.exit(0)
print(int(time.time() - rec["last_update"]))
PY
}

FRESH=60   # a worker reporting within 60s is live
age="$(worker_age)"
case "$age" in
  down:*) done_ 20 "Can't reach the server ($age). Check WiFi / VPN, then click again." ;;
  rejected:*) done_ 20 "Server rejected this machine ($age). Send this screen to Bernardo." ;;
  never) say "relay OK; worker '$NAME' not registered yet" ;;
  *)     if [ "$age" -le "$FRESH" ] && [ -z "${RESCUE_FORCE_RESTART:-}" ]; then
           say "✓ worker '$NAME' already connected (${age}s ago)"
           done_ 0 "Already connected. Nothing to do."
         fi
         if [ -n "${RESCUE_FORCE_RESTART:-}" ]; then
           say "code changed on GitHub — restarting worker to load it"
         else
           say "relay OK; worker '$NAME' stale (${age}s) — will restart"
         fi
         ;;
esac

if [ "$STATUS_ONLY" -eq 1 ]; then
  done_ 10 "Not connected (worker ${age}). Click the button to reconnect."
fi

# Prefer the durable path (user systemd service) when installed — it needs no
# password. Fall back to the tmux bring-up (node-up.sh) otherwise. Exactly ONE
# mechanism runs, so two workers never poll at once.
UNIT=tcpuxdo-worker.service
if systemctl --user list-unit-files "$UNIT" >/dev/null 2>&1 \
   && systemctl --user cat "$UNIT" >/dev/null 2>&1; then
  say "restarting user service $UNIT"
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  systemctl --user restart "$UNIT"   || done_ 50 "Could not start the worker service. Call Bernardo."
else
  # node-up.sh intentionally leaves a busy worker pane alone. When the relay
  # reports a stale worker, that pane may still run old code or old config.
  if tmux has-session -t "${WORKER_SESSION:-tcpuxdo-worker}" 2>/dev/null \
     && tmux list-panes -t "${WORKER_SESSION:-tcpuxdo-worker}" -F '#{pane_title}' \
        | grep -Fxq "${WORKER_PANE_MAIN:-tcpuxdo-worker-main}"; then
    say "restarting existing worker pane with current code and .env"
    bash setup/worker-restart.sh >/dev/null 2>&1 || done_ 50 "Could not restart the worker pane. Call Bernardo."
  else
    say "starting worker via setup/node-up.sh"
    bash setup/node-up.sh >/dev/null 2>&1 || done_ 50 "Could not start the worker. Call Bernardo."
  fi
fi

# Verify against the relay — a started process is not a registered worker.
for _ in $(seq 1 9); do
  sleep 3
  age="$(worker_age)"
  case "$age" in
    down:*) done_ 20 "Can't reach the server ($age). Check WiFi / VPN, then click again." ;;
    rejected:*) done_ 20 "Server rejected this machine ($age). Send this screen to Bernardo." ;;
    never) ;;
    *) [ "$age" -le "$FRESH" ] && { say "✓ connected (${age}s ago)"; done_ 0 "Connected. You can close this."; } ;;
  esac
done
if systemctl --user cat "$UNIT" >/dev/null 2>&1; then
  say "service log (relay still has no fresh heartbeat):"
  journalctl --user -u "$UNIT" -n 8 --no-pager 2>/dev/null | tail -8 >&2
else
  pane="$(tmux list-panes -t "${WORKER_SESSION:-tcpuxdo-worker}" -a \
    -F '#{pane_id} #{pane_title}' 2>/dev/null | awk -v t="${WORKER_PANE_MAIN:-tcpuxdo-worker-main}" '$2==t {print $1; exit}')"
  [ -z "$pane" ] || tmux capture-pane -p -t "$pane" -S -12 2>/dev/null | tail -12 >&2
fi
done_ 10 "Worker did not report to relay. Send this screen to Bernardo."
