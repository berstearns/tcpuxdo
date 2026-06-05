# pane: `tcpuxdo-worker-main` (tty node) — the PULLER

Role: poll the relay, report this node's pane state, execute queued tmux ops locally. Session
`tcpuxdo-worker`, window `worker`, pane title `tcpuxdo-worker-main`, cwd `<node-root>`
(the clone, e.g. `~/tcpuxdo`), running as the user that owns your Claude pane.
Brought up **on the node** — clone + `.env` + `bash setup/node-up.sh` — never over SSH from main.

> Real per-deployment values are masked as `<…>`. The unmasked copy lives in the git-ignored
> `runbook/`.

## Command run

```sh
cd <node-root> && set -o allexport && source .env && set +o allexport && \
  python3 worker.py --name <node> --host <relay-ip>
```

Polls every `TCPUX_POLL`s, reports panes every `TCPUX_SYNC`s. Sibling pane `tcpuxdo-worker-obs`
runs a 3s `tmux list-panes -a` dump so you can see exactly what the worker sees.

## Gotcha hit

- Worker dials the **relay** host (`<relay-ip>`), not `0.0.0.0`/`127.0.0.1`. Set
  `TCPUX_HOST=<relay-ip>` in the node's `.env`; `node-up.sh` passes it as `--host`.
- If polls silently get nothing, the node's egress IP probably isn't allowed yet:
  run `tcpuxdo allow <node-egress-ip>` (from anywhere holding the admin token).
- `TCPUX_WORKER` must be unique per node. Two nodes sharing a name collide in the relay's registry
  and ops route to whichever reported last.

## Equivalent repo script

```sh
# ON the node (the only supported path — no SSH push from main):
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo && cd ~/tcpuxdo
cp .env.example .env   # set TCPUX_HOST=<relay>, TCPUX_PORT, TCPUX_WORKER=<node>
bash setup/node-up.sh
```

## Notes

- The worker re-reads live pane state *before* each `send-keys`; the busy/idle decision is fresh,
  not from the last report.
- Start your Claude Code session in a pane on this node; it shows up as `idle` (cmd `claude`) and
  becomes a safe `send-keys` target. Register it as a shortcut from main for easy addressing.
