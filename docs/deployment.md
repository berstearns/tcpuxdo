# Deployment

Three roles, deployed in order. All real values live in the git-ignored `.env`; the scripts read
them from there. See `.env.example` for every key.

## 0. Configure (on main)

```sh
cp .env.example .env
$EDITOR .env
# minimum: TCPUX_HOST (relay ip), TCPUX_PORT, TCPUX_ADMIN_PORT, TCPUX_ADMIN_TOKEN
ln -s "$PWD/tcpuxdo" ~/bin/tcpuxdo
```

Generate the admin token with `openssl rand -hex 32`.

## 1. Relay (the VPS that holds the queue)

```sh
bash setup/00-preflight.sh      # ssh reachable? python3 + tmux present?
bash setup/01-relay-deploy.sh   # ship engine, start queue in a titled tmux session
bash setup/02-open-ports.sh     # open TCPUX_PORT + TCPUX_ADMIN_PORT on the firewall
```

`01` writes a relay-scoped `.env` on the VPS (binds `0.0.0.0`) and runs `remote-queue.sh`, which
brings up the `tcpuxdo-queue` session with three titled panes:

| pane title | runs |
|------------|------|
| `tcpuxdo-queue-server` | `server.py` — the axiom-checked queue |
| `tcpuxdo-queue-admin`  | `allowlist_server.py serve` — IP allowlist admin |
| `tcpuxdo-queue-state`  | a 5s `state` poller (live view of nodes + queues) |

Lock the gate immediately:

```sh
tcpuxdo allow <main-egress-ip>
tcpuxdo allow <each-node-egress-ip>
tcpuxdo get
```

Prefer to daemonize instead of a tmux pane? Use `setup/tcpuxdo.service`.

## 2. Nodes (each tty box, once)

```sh
NODE_SSH=user@nodeA TCPUX_WORKER=nodeA RUN_USER=claude \
  bash setup/03-node-onboard.sh
```

See [onboard-tty-node.md](./onboard-tty-node.md) for the per-node detail and the non-root
Claude-Code user.

## 3. Verify (from main)

```sh
bash setup/04-verify.sh nodeA
tcpuxdo list nodeA          # see the node's panes (idle/busy)
```

## Day-to-day

```sh
tcpuxdo list                                  # all nodes + panes
tcpuxdo -w nodeA -p work:1:1 -c 'git pull'    # send-keys to a pane
tcpuxdo shortcut set claude-main -w nodeA -p work:1:1
tcpuxdo -s claude-main -c '/compact'          # send to the Claude pane by name
```

> Pane indices are 1-based here (`pane-base-index=1`), so the first pane is `.1`.
