# Onboard a tty node

One node = one `worker.py` polling the relay and executing tmux ops locally. Run
`setup/03-node-onboard.sh` once per node; it is idempotent.

## Command

```sh
NODE_SSH=user@nodeA \
NODE_ROOT=/home/claude/tcpuxdo \
TCPUX_WORKER=nodeA \
RUN_USER=claude \
  bash setup/03-node-onboard.sh
```

| var | meaning |
|-----|---------|
| `NODE_SSH` | ssh target of the node (required) |
| `TCPUX_WORKER` | worker name — **must be unique per node**; how you address it from main (required) |
| `NODE_ROOT` | install dir on the node (default `/home/<user>/tcpuxdo`) |
| `RUN_USER` | user the worker (and Claude Code) run as |

## What it does

1. `scp`s the engine + `remote-worker.sh` to `NODE_ROOT`.
2. Writes a node `.env` that **dials the relay** (`TCPUX_HOST=<relay>`, `TCPUX_PORT`), sets the
   worker name, poll/sync intervals, and `TCPUX_IDLE_CMDS` (includes `claude`).
3. Runs `remote-worker.sh`, which starts the `tcpuxdo-worker` session with two titled panes:

| pane title | runs |
|------------|------|
| `tcpuxdo-worker-main` | `worker.py --name <node>` — the poll/exec/ack loop |
| `tcpuxdo-worker-obs`  | a 3s `tmux list-panes -a` dump — live view of what the worker sees |

## The Claude Code pane

- Claude Code refuses `--dangerously-skip-permissions` as root, so run the worker as a non-root
  `RUN_USER`. The worker then drives panes owned by that user.
- Because `claude` is in `TCPUX_IDLE_CMDS`, a pane running Claude Code is `idle` (safe to type into).
  A pane running a build is `busy` and `send-keys` is refused (`SK5`).
- Start your Claude session in a pane on the node, note its `session:window:pane`, and register a
  shortcut from main:

  ```sh
  tcpuxdo list nodeA                                   # find the pane id
  tcpuxdo shortcut set nodeA-claude -w nodeA -p work:1:1
  tcpuxdo -s nodeA-claude -c 'summarize the last test run'
  ```

## Allowlist

The node's egress IP must be allowed on the relay, or its polls are rejected before reaching the
queue:

```sh
tcpuxdo allow <node-egress-ip>     # run from main, once per node
```
