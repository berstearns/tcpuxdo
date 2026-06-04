#!/usr/bin/env bash
# Open the queue + admin ports on the relay. Tries the DigitalOcean cloud
# firewall (if TCPUX_DO_FW_ID is set) and ufw on the host. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_err $LINENO' ERR

: "${ADMIN_PORT:?set TCPUX_ADMIN_PORT in .env}"

if [ -n "$DO_FW_ID" ]; then
  say "DigitalOcean cloud firewall ($DO_FW_ID): allow $PORT, $ADMIN_PORT"
  doctl compute firewall add-rules "$DO_FW_ID" \
    --inbound-rules "protocol:tcp,ports:$PORT,address:0.0.0.0/0 protocol:tcp,ports:$ADMIN_PORT,address:0.0.0.0/0" \
    && echo "DO firewall rules added" || echo "DO firewall add-rules failed (already open?)"
else
  echo "TCPUX_DO_FW_ID unset — skipping DO cloud firewall"
fi

say "Host ufw on relay: allow $PORT, $ADMIN_PORT"
ssh "${SSH_OPTS[@]}" "$VPS_SSH" "command -v ufw >/dev/null && { ufw allow $PORT/tcp; ufw allow $ADMIN_PORT/tcp; ufw status | head; } || echo 'ufw not present — skipping'" || true

say "REMINDER: lock down with the IP allowlist"
echo "  tcpuxdo allow <your-main-ip>     # and each node's egress ip"
echo "  tcpuxdo get                      # confirm"
echo "OPEN_PORTS_DONE"
