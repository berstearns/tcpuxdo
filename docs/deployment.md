# Deployment

**One pattern for every machine: `git clone` → `cp .env.example .env` → one command.**
Real values live only in the git-ignored `.env`. The repo is public; your deployment is not.

| Role | Where you run it | The one command |
|------|------------------|-----------------|
| **relay** | on the VPS (default) | `bash setup/relay-up.sh` |
| **node** | on the tty box | `bash setup/node-up.sh` |
| **main** | your laptop | `tcpuxdo …` (after `ln -s "$PWD/tcpuxdo" ~/bin/tcpuxdo`) |

> **The one exception:** the **relay** may instead be deployed *from main over SSH* with
> `setup/01-relay-deploy.sh` (handy for a fresh VPS you don't want to clone on). It just ships this
> repo + runs `relay-up.sh` remotely. **Nodes have no such path** — always bring a node up on the
> node itself.

---

## Relay

**Default — on the VPS:**
```sh
git clone https://github.com/berstearns/tcpuxdo /srv/tcpuxdo && cd /srv/tcpuxdo
cp .env.example .env      # set TCPUX_PORT, TCPUX_ADMIN_PORT, TCPUX_ADMIN_TOKEN (openssl rand -hex 32)
bash setup/relay-up.sh
```

**Exception — from main over SSH:**
```sh
export TCPUX_HOST=<relay-ip> TCPUX_PORT=9100 TCPUX_ADMIN_PORT=9101
export TCPUX_ADMIN_TOKEN=$(openssl rand -hex 32)   # save this
bash setup/00-preflight.sh      # ssh reachable? python3 + tmux present?
bash setup/01-relay-deploy.sh   # ship repo + run relay-up.sh remotely
bash setup/02-open-ports.sh     # open the ports on the relay firewall
```

Either way the relay ends up with the `tcpuxdo-queue` session, three titled panes:

| pane | runs |
|------|------|
| `tcpuxdo-queue-server` | `server.py` — the axiom-checked queue |
| `tcpuxdo-queue-admin`  | `allowlist_server.py serve` — IP-allowlist admin |
| `tcpuxdo-queue-state`  | a 5s `state` poller |

Open the ports (cloud firewall + host) and lock the gate:
```sh
tcpuxdo allow <main-ip>          # and each node's egress ip
tcpuxdo get
```

## Node (each tty box)

On the node — see [onboard-tty-node.md](./onboard-tty-node.md):
```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo && cd ~/tcpuxdo
cp .env.example .env             # TCPUX_HOST=<relay-ip>, TCPUX_PORT, TCPUX_WORKER=<unique>
bash setup/node-up.sh
# then, from anywhere with the admin token:
tcpuxdo allow <node-egress-ip>
```

## Main (your laptop)

```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo && cd ~/tcpuxdo
cp .env.example .env             # TCPUX_HOST=<relay-ip>, TCPUX_PORT, admin pair + TCPUX_ADMIN_HOST=$TCPUX_HOST
ln -s "$PWD/tcpuxdo" ~/bin/tcpuxdo
tcpuxdo doctor
```

## Day-to-day (from main)

```sh
tcpuxdo list                                  # all nodes + panes
tcpuxdo -w nodeA -p work:1:1 -c 'git pull'    # send-keys to a pane
tcpuxdo shortcut set claude-main -w nodeA -p work:1:1
tcpuxdo -s claude-main -c '/compact'          # send to the Claude pane by name
tcpuxdo read -s claude-main                    # capture that pane's text back (stdout)
tcpuxdo read -s claude-main --lines 200        # include 200 lines of scrollback
```

> Pane indices are 1-based (`pane-base-index=1`), so the first pane is `.1`.

## Verify (from main)

```sh
bash setup/04-verify.sh nodeA
```
