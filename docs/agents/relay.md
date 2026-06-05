# AGENT RUNBOOK — role: RELAY

You are an agent bringing up the **relay** (the queue) on a VPS. Execute the steps in order. Do not
improvise commands. Stop and report if any **Verify** check fails. Never print, echo, or commit the
value of any key marked `SECRET`.

Default path is **on the VPS** (clone + .env + one command). An SSH-from-main path exists as an
exception — see the end.

## Inputs (from `.env` — set values, never hardcode them in tracked files)

| Key | Required | Secret | How to obtain / value |
|-----|----------|--------|-----------------------|
| `TCPUX_PORT` | yes | no | an unused TCP port for the queue, e.g. `9100`. Check free: `ss -tlnp \| grep :PORT` |
| `TCPUX_ADMIN_PORT` | yes | no | a second unused port for allowlist admin, e.g. `9101` |
| `TCPUX_ADMIN_TOKEN` | yes | **SECRET** | generate once: `openssl rand -hex 32`. The same value must be set on **main** |
| `TCPUX_HOST` | no | no | bind address; defaults to `0.0.0.0` (correct for the relay) |
| `TCPUX_ALLOWLIST_DB` | no | no | defaults to `<repo>/allowlist.json`; seeded from `allowlist.seed.json` on first run |

## Preconditions (assert before starting)

```sh
command -v python3 && command -v tmux        # both must exist
ss -tlnp | grep -E ":${TCPUX_PORT}|:${TCPUX_ADMIN_PORT}" && echo "PORT IN USE — pick others" || echo "ports free"
```

## Steps

```sh
git clone https://github.com/berstearns/tcpuxdo /srv/tcpuxdo
cd /srv/tcpuxdo
cp .env.example .env
# edit .env to set TCPUX_PORT, TCPUX_ADMIN_PORT, and:
printf 'TCPUX_ADMIN_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env   # SECRET — do not echo it
bash setup/relay-up.sh
```

`relay-up.sh` is idempotent and starts the `tcpuxdo-queue` tmux session with three titled panes:
`tcpuxdo-queue-server` (`server.py`), `tcpuxdo-queue-admin` (`allowlist_server.py serve`),
`tcpuxdo-queue-state` (5s poll).

## Verify (all must pass)

```sh
# 1. session + panes exist
tmux has-session -t tcpuxdo-queue && \
  tmux list-panes -t tcpuxdo-queue -F '#{pane_title} #{pane_current_command}'
# expect: three lines incl. tcpuxdo-queue-server running python3

# 2. queue answers on loopback  (source .env first so TCPUX_PORT is set)
cd /srv/tcpuxdo && set -o allexport && . ./.env && set +o allexport
python3 -c "import os; from proto import rpc; print(rpc('127.0.0.1', int(os.environ['TCPUX_PORT']), {'op':'state'}))"
# expect a dict with "ok": True

# 3. ports listening
ss -tlnp | grep -E ":${TCPUX_PORT}|:${TCPUX_ADMIN_PORT}"
# expect both, owned by python3
```

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `tcpuxdo-queue-server` pane shows a shell, not `python3` | `.env` not sourced into the pane | `relay-up.sh` bakes in `source .env`; re-run it; check `.env` has `TCPUX_PORT` |
| server pane logs `dev mode, no ip gate` | `TCPUX_ALLOWLIST_DB` unset | set it in `.env` (default points at `<repo>/allowlist.json`); re-run |
| port already in use | another service on that port | pick free `TCPUX_PORT`/`TCPUX_ADMIN_PORT`, re-run |
| a stale `tcpuxdo-queue` had an old token | prior deploy left panes running | `tmux kill-session -t tcpuxdo-queue` then `bash setup/relay-up.sh` |

## Done when

`tmux has-session -t tcpuxdo-queue` is true, both ports listen, and the loopback `state` rpc
returns `ok: True`. Then open the firewall for `TCPUX_PORT`+`TCPUX_ADMIN_PORT` and have **main**
run `tcpuxdo allow <ip>` for itself and each node.

## Exception path (deploy from main over SSH)

If you are an agent running **on main** with SSH to the VPS, you may instead:
`bash setup/00-preflight.sh && bash setup/01-relay-deploy.sh && bash setup/02-open-ports.sh`.
This ships the repo and runs `relay-up.sh` remotely. Requires the same `.env` inputs on main.
