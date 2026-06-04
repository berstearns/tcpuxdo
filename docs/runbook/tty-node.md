# pane: `tcpuxdo-worker-main` (tty node) — the PULLER

Role: poll the relay, report this node's pane state, execute queued tmux ops locally. Session
`tcpuxdo-worker`, window `worker`, pane title `tcpuxdo-worker-main`, cwd `<node-root>`
(default `/home/<run-user>/tcpuxdo`), running as `<run-user>` (e.g. `claude`).

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

- Worker dials the **relay** host (`<relay-ip>`), not `0.0.0.0`. The node `.env` written by
  `03-node-onboard.sh` sets `TCPUX_HOST=<relay-ip>` precisely for this.
- If polls silently get nothing, the node's egress IP probably isn't allowed yet:
  run `tcpuxdo allow <node-egress-ip>` from main.
- `--name` must be unique per node. Two nodes sharing a name collide in the relay's registry and
  ops route to whichever reported last.

## Equivalent repo script

```sh
NODE_SSH=<user>@<node> TCPUX_WORKER=<node> RUN_USER=<run-user> \
  bash setup/03-node-onboard.sh      # from main: ship + start this pane
```

## Notes

- The worker re-reads live pane state *before* each `send-keys`; the busy/idle decision is fresh,
  not from the last report.
- Start your Claude Code session in a pane on this node; it shows up as `idle` (cmd `claude`) and
  becomes a safe `send-keys` target. Register it as a shortcut from main for easy addressing.
