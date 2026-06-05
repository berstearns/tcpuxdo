# Onboard a tty node

One node = one `worker.py` polling the relay and executing tmux ops locally. Nodes follow the
**default tcpuxdo pattern — done ON the node**: clone, set `.env`, run one command. They are
**not** deployed over SSH from main (only the relay has that exception).

## On the node (3 steps)

```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo
cd ~/tcpuxdo
cp .env.example .env && $EDITOR .env     # set the 3 lines below
bash setup/node-up.sh                    # the single command
```

The only `.env` lines a node needs:

```sh
TCPUX_HOST=<relay-ip>     # the node DIALS the relay (never 0.0.0.0 / 127.0.0.1)
TCPUX_PORT=<queue-port>   # e.g. 9100
TCPUX_WORKER=<nodeA>      # unique per node — how main addresses it
```

A node holds **no secret** — no admin token, no key. It's authenticated by its source IP at the
relay's gate (see allowlist below).

## What `node-up.sh` does

Idempotent. Reads `.env`, then starts the `tcpuxdo-worker` session with two titled panes:

| pane title | runs |
|------------|------|
| `tcpuxdo-worker-main` | `worker.py --name <node> --host <relay> --port <port>` — poll/exec/ack loop |
| `tcpuxdo-worker-obs`  | a 3s `tmux list-panes -a` dump — live view of what the worker sees |

## Allowlist the node (once, from anywhere with the admin token)

The node's egress IP must be on the relay's allowlist or its polls are rejected:

```sh
# on the node, find its public IP:
curl -s ifconfig.me
# from main (or any box with .env's admin token):
tcpuxdo allow <node-egress-ip>
tcpuxdo list <node>           # confirm it registered
```

## The Claude Code pane

- Run the worker as the same user that owns your Claude pane. Claude Code refuses
  `--dangerously-skip-permissions` as root, so use a non-root user on the node.
- `claude` is in `TCPUX_IDLE_CMDS`, so a pane running Claude Code is `idle` (safe to type into); a
  pane running a build is `busy` and `send-keys` is refused (`SK5`).
- Start your Claude session in a pane on the node, find its id, and address it from main:

  ```sh
  tcpuxdo list <node>                                   # find the pane id (1-based!)
  tcpuxdo shortcut set <node>-claude -w <node> -p work:1:1
  tcpuxdo -s <node>-claude -c 'summarize the last test run'
  ```
