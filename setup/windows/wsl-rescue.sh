#!/usr/bin/env bash
#===============================================================================
# WHAT:    wsl-rescue.sh — ONE command that brings the WSL tcpuxdo worker back,
#          for a NON-technical person who only pastes a line into WSL:
#
#            curl -fsSL https://raw.githubusercontent.com/berstearns/tcpuxdo/master/setup/windows/wsl-rescue.sh | bash
#
#          (when the node has no .env at all, Bernardo sends the same line with
#           the relay address appended:  … | bash -s -- <relay-host>[:port] )
#
#          It does everything, in order, and ends with ONE big verdict:
#            1. checks git / python3 / tmux / curl
#            2. FINDS the existing tcpuxdo checkout (the one with a .env), or
#               clones the public repo into ~/tcpuxdo
#            3. updates it to the latest master (local edits are stashed, never lost)
#            4. makes sure .env has TCPUX_HOST / TCPUX_PORT / TCPUX_WORKER=wsl-
#            5. links ~/tcpuxdo → that checkout (so the Desktop button works later)
#            6. asks the relay directly and PRINTS the exact answer — including a
#               rejection code like N1_IP_NOT_ALLOWED + this machine's public IP
#            7. runs setup/windows/AUTO-worker-bringup.sh and waits for "connected"
#            8. best effort: installs the autostart service
#
# WHY:     2026-10-03: the wsl- worker had been silent 24 days. Bernardo has no
#          access to that machine and the person there is not technical: a
#          multi-step guide failed at step 1 (~/tcpuxdo did not exist). Recovery
#          must be one pasted line that diagnoses AND fixes, and that says, in
#          one screen, what to send back when it cannot fix.
#
# INPUTS:  $1 (optional)  relay host[:port] — only used when no .env has one.
#          env TCPUXDO_DIR  force a checkout path (skips the search)
#          env TCPUX_WORKER worker name to ensure (default wsl-)
#          env RESCUE_STOP_BEFORE_BRINGUP=1  test mode: steps 1-6 only, no worker
#          env RESCUE_REPO_URL  clone source (tests: a local path)
# OUTPUTS: a log ~/tcpuxdo-rescue-<stamp>.log (or RESCUE_LOG_FILE);
#          last screen = verdict:
#            "RESULT: OK — connected"   or   "RESULT: PROBLEM — <reason>"
#          exit 0 connected · 1 problem
# SECRETS: none. The relay address is NOT in this public file; the admin token
#          is never needed on a node.
# RE-RUN SAFETY: idempotent — safe to paste again and again.
#===============================================================================
set -uo pipefail
RELAY_ARG="${1:-}"
WNAME="${TCPUX_WORKER:-wsl-}"
REPO_URL="${RESCUE_REPO_URL:-https://github.com/berstearns/tcpuxdo.git}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${RESCUE_LOG_FILE:-$HOME/tcpuxdo-rescue-$STAMP.log}"
exec > >(tee -a "$LOG") 2>&1

say(){ echo "  · $*"; }
ok(){ echo "  ✓ $*"; }
verdict_ok(){ echo; echo "=================================================="; echo " RESULT: OK — connected ($*)"; echo " You can close this window."; echo "=================================================="; exit 0; }
verdict_bad(){ echo; echo "=================================================="; echo " RESULT: PROBLEM — $*"; echo " Take a photo of THIS screen and send it to Bernardo."; echo " (log file: $LOG)"; echo "=================================================="; exit 1; }

echo "tcpuxdo WSL rescue — $STAMP — user $(whoami) on $(hostname)"

# 1 — tools
missing=()
for c in git python3 tmux curl; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [ "${#missing[@]}" -gt 0 ]; then
    say "missing: ${missing[*]} — trying to install (only works without a password)"
    sudo -n apt-get update -qq >/dev/null 2>&1 && sudo -n apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    missing=(); for c in git python3 tmux curl; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ "${#missing[@]}" -eq 0 ] || verdict_bad "programs missing: ${missing[*]} (needs: sudo apt-get install -y ${missing[*]})"
fi
ok "programs: git python3 tmux curl"

# 2 — find the checkout (prefer one that already has a .env with a relay)
DIR="${TCPUXDO_DIR:-}"
if [ -z "$DIR" ]; then
    while IFS= read -r envf; do
        d="$(dirname "$envf")"
        if [ -f "$d/worker.py" ] && grep -q '^TCPUX_HOST=' "$envf"; then DIR="$d"; break; fi
    done < <(find "$HOME" -maxdepth 5 -type f -name .env -path '*tcpuxdo*' 2>/dev/null)
fi
if [ -z "$DIR" ]; then
    while IFS= read -r wf; do DIR="$(dirname "$wf")"; break; done < <(find "$HOME" -maxdepth 5 -type f -name worker.py -path '*tcpuxdo*' 2>/dev/null)
fi
if [ -z "$DIR" ]; then
    DIR="$HOME/tcpuxdo"
    say "no tcpuxdo copy found — downloading it to $DIR"
    git clone -q "$REPO_URL" "$DIR" || verdict_bad "could not download $REPO_URL (internet?)"
fi
ok "tcpuxdo folder: $DIR"

# 3 — latest master (never lose local edits: stash them)
cd "$DIR" || verdict_bad "cannot enter $DIR"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REPO_URL" || verdict_bad "could not set GitHub source"
else
    git remote add origin "$REPO_URL" || verdict_bad "could not set GitHub source"
fi
OLD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    git stash push -q -m "wsl-rescue-$STAMP" && say "local edits saved in: git stash (wsl-rescue-$STAMP)"
fi
git fetch -q origin master || verdict_bad "could not update from GitHub (internet?)"
git checkout -q master 2>/dev/null || git checkout -q -b master origin/master || verdict_bad "git checkout master failed"
git reset -q --hard origin/master || verdict_bad "git update failed"
NEW_SHA="$(git rev-parse HEAD)"
[ "$OLD_SHA" = "$NEW_SHA" ] || export RESCUE_FORCE_RESTART=1
ok "code updated to $(git rev-parse --short HEAD) (GitHub master)"

# 4 — .env
touch .env
if ! grep -q '^TCPUX_HOST=.\+' .env; then
    [ -n "$RELAY_ARG" ] || verdict_bad "no relay address on this machine. Ask Bernardo for the command WITH the address at the end."
    h="${RELAY_ARG%%:*}"; p="${RELAY_ARG#*:}"; [ "$p" = "$RELAY_ARG" ] && p=9100
    sed -i '/^TCPUX_HOST=/d;/^TCPUX_PORT=/d' .env
    printf 'TCPUX_HOST=%s\nTCPUX_PORT=%s\n' "$h" "$p" >> .env
    say "relay address written to .env"
fi
grep -q '^TCPUX_PORT=.\+' .env || echo "TCPUX_PORT=9100" >> .env
if grep -q '^TCPUX_WORKER=' .env; then
    sed -i "s/^TCPUX_WORKER=.*/TCPUX_WORKER=$WNAME/" .env
else
    echo "TCPUX_WORKER=$WNAME" >> .env
fi
chmod 600 .env
ok ".env ready (worker name: $WNAME)"

# 5 — ~/tcpuxdo link for the Desktop button
if [ "$DIR" != "$HOME/tcpuxdo" ] && [ ! -e "$HOME/tcpuxdo" ]; then
    ln -s "$DIR" "$HOME/tcpuxdo" && say "linked ~/tcpuxdo → $DIR"
fi

# 6 — ask the relay directly, print its exact answer
set -a
# shellcheck disable=SC1091 # Node-specific, git-ignored config.
. ./.env
set +a
PUBIP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo unknown)"
say "this machine's public IP: $PUBIP"
RELAY_SAYS="$(PYTHONPATH="$DIR" TCPUX_CONNECT_RETRY_SECS=20 python3 - <<'PY' 2>&1
import os, socket
socket.setdefaulttimeout(8)
from proto import rpc
try:
    r = rpc(os.environ["TCPUX_HOST"], int(os.environ["TCPUX_PORT"]), {"op": "state"})
except Exception as e:
    print("UNREACHABLE", type(e).__name__, e); raise SystemExit
if r.get("ok") is False:
    print("REJECTED", r.get("err_code"), "-", r.get("hint", ""))
else:
    print("OK", len(r.get("state", {})), "workers registered")
PY
)"
say "relay says: $RELAY_SAYS"
case "$RELAY_SAYS" in
    UNREACHABLE*) verdict_bad "cannot reach the server (internet / VPN?). $RELAY_SAYS" ;;
    REJECTED*)    verdict_bad "the server refuses this machine: $RELAY_SAYS — public IP $PUBIP must be allowed (Bernardo: tcpuxdo allow $PUBIP)" ;;
esac
ok "server reachable and accepts this machine"
# test hook (main laptop only): stop before starting a real worker
[ -n "${RESCUE_STOP_BEFORE_BRINGUP:-}" ] && verdict_ok "TEST MODE — stopped before bring-up"

# 7 — bring the worker up and wait for it to register
out="$(TCPUXDO_DIR="$DIR" bash setup/windows/AUTO-worker-bringup.sh 2>&1)"
printf '%s\n' "$out" | awk '{print "    " $0}'
code="$(echo "$out" | grep -o 'BRINGUP_RESULT=[0-9]*' | tail -1 | cut -d= -f2)"
for _ in 1 2 3 4; do
    [ "$code" = 0 ] && break
    [ "$code" = 10 ] || break
    sleep 15
    out="$(TCPUXDO_DIR="$DIR" bash setup/windows/AUTO-worker-bringup.sh --status 2>&1)"
    printf '%s\n' "$out" | awk '{print "    " $0}'
    code="$(echo "$out" | grep -o 'BRINGUP_RESULT=[0-9]*' | tail -1 | cut -d= -f2)"
done

# 8 — autostart (best effort, never blocks the verdict)
if [ "$code" = 0 ] && [ -f setup/windows/Install-Worker-Autostart.sh ] \
   && ! systemctl --user cat tcpuxdo-worker.service >/dev/null 2>&1; then
    if RESCUE_NONINTERACTIVE=1 bash setup/windows/Install-Worker-Autostart.sh >/dev/null 2>&1; then
        say "autostart installed"
    else
        say "autostart not installed (worker is connected)"
    fi
fi

case "$code" in
    0)  verdict_ok "worker $WNAME" ;;
    10) verdict_bad "worker started but not registered after 1 minute (code 10)" ;;
    20) verdict_bad "worker cannot reach or was rejected by relay (code 20); public IP $PUBIP may need allowing" ;;
    *)  verdict_bad "bring-up code ${code:-none}: $(echo "$out" | grep -o 'BRINGUP_MSG=.*' | tail -1 | cut -d= -f2-)" ;;
esac
