#!/usr/bin/env bash
# WHAT:    One-time durable install (run by Bernardo IN WSL): make the tcpuxdo
#          worker a user systemd service that starts on boot and restarts on
#          crash, so the Desktop button becomes a rare manual override.
# WHY:     "Solve this kind of problem" = the worker should not stay dead for
#          22h again. systemd is the supervisor; lingering starts it before any
#          login. After this, Reconnect-Worker.vbs only needs a click for an
#          unusual outage, not every reboot.
# INPUTS:  env TCPUXDO_DIR   repo path (default: $HOME/tcpuxdo)
#          --status          report install state, change nothing
# OUTPUTS: installs ~/.config/systemd/user/tcpuxdo-worker.service, enables it,
#          enables linger (one sudo). Prints INSTALL_RESULT=<0 ok|1 needs-systemd|2 error>.
# USAGE (combinatorial):
#   bash setup/windows/Install-Worker-Autostart.sh          # the install
#   bash setup/windows/Install-Worker-Autostart.sh --status # inspect only
#   TCPUXDO_DIR=/opt/tcpuxdo bash …/Install-Worker-Autostart.sh
# RE-RUN SAFETY: idempotent — re-renders the unit, re-enables; safe to repeat.
set -uo pipefail
REPO="${TCPUXDO_DIR:-$HOME/tcpuxdo}"
STATUS=0; [ "${1:-}" = "--status" ] && STATUS=1
NAME="$( [ -f "$REPO/.env" ] && (set -a; . "$REPO/.env"; set +a; echo "${TCPUX_WORKER:-$(hostname)}") || hostname )"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/tcpuxdo-worker.service"

echo "repo=$REPO  worker-name=$NAME"
if [ ! -d /run/systemd/system ]; then
  cat <<EOF
systemd is NOT running in this WSL distro. Enable it once:
  1) put this in /etc/wsl.conf  (sudo):   [boot]
                                          systemd=true
  2) in Windows PowerShell:   wsl --shutdown
  3) reopen WSL and re-run this script.
INSTALL_RESULT=1
EOF
  exit 1
fi

if [ "$STATUS" -eq 1 ]; then
  systemctl --user is-enabled tcpuxdo-worker.service 2>/dev/null || echo "unit: not installed"
  systemctl --user is-active  tcpuxdo-worker.service 2>/dev/null || true
  loginctl show-user "$USER" -p Linger 2>/dev/null || true
  echo "INSTALL_RESULT=0"; exit 0
fi

[ -f "$REPO/.env" ] || { echo "missing $REPO/.env — cp .env.example .env and set TCPUX_HOST/PORT/WORKER first"; echo "INSTALL_RESULT=2"; exit 2; }

mkdir -p "$UNIT_DIR"
sed -e "s#__REPO__#$REPO#g" -e "s#__NAME__#$NAME#g" \
    "$REPO/setup/windows/tcpuxdo-worker.service" > "$UNIT"
echo "wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable --now tcpuxdo-worker.service || { echo "INSTALL_RESULT=2"; exit 2; }

# Linger = start the user manager (and this service) at boot without a login.
# The only sudo in the whole design, and only here, once.
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
  echo "enabling linger (one sudo prompt) so the worker starts before you log in…"
  sudo loginctl enable-linger "$USER" || echo "  (linger not set — worker still runs while logged in)"
fi

sleep 3
systemctl --user --no-pager status tcpuxdo-worker.service | sed -n '1,6p'
echo "INSTALL_RESULT=0"
