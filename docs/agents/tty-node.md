# AGENT RUNBOOK — role: TTY-NODE (a headless box that runs tmux + Claude Code)

You are an agent bringing up a **node**: a worker that polls the relay and executes tmux ops
locally (including `send-keys` into a Claude Code pane). Run these steps **on the node itself** —
nodes are never deployed over SSH from main. Stop and report on any **Verify** failure. A node
holds **no secret**.

## Inputs (from `.env`)

| Key | Required | Secret | Value |
|-----|----------|--------|-------|
| `TCPUX_HOST` | yes | no | the **relay** IP/DNS. The worker dials this — never `0.0.0.0`/`127.0.0.1` |
| `TCPUX_PORT` | yes | no | the relay's queue port |
| `TCPUX_WORKER` | yes | no | a name **unique across all nodes**; how main addresses this node |
| `TCPUX_IDLE_CMDS` | no | no | pane commands treated as safe-to-type-into; default includes `claude` |
| `TCPUX_POLL` / `TCPUX_SYNC` | no | no | poll / state-report intervals (default 2s / 5s) |

## Preconditions (assert before starting)

```sh
command -v python3 && command -v tmux                 # both required
# relay reachable from this node:
timeout 5 bash -c "</dev/tcp/${TCPUX_HOST}/${TCPUX_PORT}" && echo "relay reachable" || echo "BLOCKED — check TCPUX_HOST/PORT + firewall"
```
Also: this node's **egress IP must be allowlisted on the relay**. Find it with `curl -s ifconfig.me`
and have an operator (or any box with the admin token) run `tcpuxdo allow <that-ip>`. Until then,
polls are silently rejected.

Run as the **non-root user that owns your Claude pane** (Claude Code refuses
`--dangerously-skip-permissions` as root).

## Steps

```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo
cd ~/tcpuxdo
cp .env.example .env
# edit .env: TCPUX_HOST=<relay-ip>  TCPUX_PORT=<port>  TCPUX_WORKER=<unique-name>
bash setup/node-up.sh
```

`node-up.sh` is idempotent and starts the `tcpuxdo-worker` session with two titled panes:
`tcpuxdo-worker-main` (`worker.py --name <node> --host <relay> --port <port>`) and
`tcpuxdo-worker-obs` (3s `tmux list-panes -a` dump).

## Verify (all must pass)

```sh
# 1. worker session + pane running
tmux has-session -t tcpuxdo-worker && \
  tmux list-panes -t tcpuxdo-worker -F '#{pane_title} #{pane_current_command}'
# expect: tcpuxdo-worker-main running python3

# 2. the relay sees this node  (run from main, or anywhere that can reach the queue)
#    on main:
#      ./tcpuxdo list <TCPUX_WORKER>
#    expect: a line for <TCPUX_WORKER> with N panes (idle/busy)

# 3. a send-keys actually lands  (run from main)
#    pick an idle pane id from `./tcpuxdo list <node>` (1-based indices), then:
#      ./tcpuxdo -w <node> -p <session:window:pane> -c 'echo tcpuxdo_ok'
#    expect: {"ok": true, ...}; the text appears in that pane (or the obs pane dump)
```

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `tcpuxdo list` never shows the node | egress IP not allowlisted | `tcpuxdo allow <node-egress-ip>` from a box with the token |
| worker exits immediately | `TCPUX_HOST`/`TCPUX_PORT` unset in `.env` | set them; re-run `node-up.sh` |
| worker connects but never gets work; main shows node missing | `TCPUX_HOST` is `0.0.0.0`/`127.0.0.1` | set it to the **relay** IP; restart: `tmux kill-session -t tcpuxdo-worker; bash setup/node-up.sh` |
| two nodes overwrite each other | duplicate `TCPUX_WORKER` | give each node a unique name |
| send-keys → `pane busy` | target pane running a non-idle cmd (`SK5`) | target an idle/`claude` pane, or wait |

## Done when

`tmux has-session -t tcpuxdo-worker` is true, `./tcpuxdo list <node>` (from main) shows the node and
its panes, and a test `send-keys` returns `ok:true` and appears in the pane.

## Claude Code pane

`claude` is in `TCPUX_IDLE_CMDS`, so a pane running Claude Code reads as **idle** — a safe
`send-keys` target. Start your Claude session in a pane, find its id with `tcpuxdo list <node>`,
then from main: `tcpuxdo shortcut set <node>-claude -w <node> -p <s:w:p>` and
`tcpuxdo -s <node>-claude -c '<prompt>'`.
