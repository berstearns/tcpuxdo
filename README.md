# tcpuxdo

Drive tmux on all your headless boxes from one laptop, through a dumb public relay.
Built for the fleet-of-tty problem: you have many `tmux` sessions on many machines — some panes
running **Claude Code** — and you want to **submit a tmux job once** and have the right node pull it
and run it, `send-keys` and all.

The dispatch engine is [tcpux](https://github.com/berstearns/tcpux): a strict, **axiom-first** TCP
command queue for tmux. The deployment skin is [credpipe](https://github.com/berstearns/credpipe)'s:
public repo, private deployment, numbered setup, masked per-pane runbooks. One queue, single
writer / many pullers.

```
   main laptop                 relay (VPS)                 tty nodes ×N
  (you, submitting)          [ job queue ]               (tmux + claude panes)
        │                     ▲        │
        └── submit :9000 ────►│        └──── poll :9000 ────►  execute tmux
            (a tmux op)       │  in-memory queue,              (send-keys into
                              │  axiom-checked,                 the claude pane)
                              │  never runs tmux itself)
```

- **Validity** comes from the *axioms* — the queue accepts **only** well-formed tmux ops
  (`send-keys`, `create-{session,window,pane}`) and rejects everything else with a stable error
  code, so a sender can react programmatically. See [AXIOMS.md](./AXIOMS.md).
- **Safety** comes from the *workers* — a worker re-reads live pane state before typing and
  **refuses to `send-keys` into a busy pane**. A pane running an idle shell — or `claude` — is
  considered safe; a pane mid-build is not.
- **The relay never runs tmux.** It holds and validates pending ops; the *node* that owns the pane
  is the only thing that ever shells out to `tmux`.

> ⚠️ This types keystrokes into live terminals on machines you own — including Claude Code panes.
> The blast radius is "whatever that pane can do." Read [Security](#security) before exposing the
> relay to anything but localhost.

---

## Why

Three roles, one queue, two directions of flow — exactly the credpipe shape, but the payload is a
tmux op instead of a credential blob:

| Role | Machine | Does |
|------|---------|------|
| **main** | your laptop with a keyboard | **submits** tmux jobs (`tcpuxdo -w … -p … -c …`) |
| **relay** | a cheap always-on VPS | holds the axiom-checked queue, hands ops to whoever polls |
| **node** | your headless tty/tmux boxes | runs a **worker** that **polls**, reports pane state, executes |

The relay exists only because main and the nodes are usually behind NAT and can't reach each other
directly. It's the public meeting point both sides *can* reach. The relay is dumb: it queues and
validates, it never touches a terminal.

---

## Dynamics — what happens on one `send-keys`

```
main                         relay (queue)                 node worker
 │  submit send-keys             │                              │
 │  -w nodeA -p s:1:1 -c "…" ───►│  axiom check (SK0…SK5)        │
 │                               │                              │
 │                               │◄──── poll (every 2s) ────────┤
 │                               │───── op: send-keys ─────────►│
 │                               │                       re-read pane state
 │                               │                       busy? ─► reject (pane busy)
 │                               │                       idle/claude ─► tmux send-keys -t s:1.1
 │                               │◄──── ack ────────────────────┤
 │                               │                       report panes (every 5s)
```

If the target pane **doesn't exist yet**, the queue rejects with `SK3_PANE_NOT_EXIST` and the client
**cascades**: `create-pane` → (if missing) `create-window` → (if missing) `create-session`, each
itself axiom-checked, then retries the `send-keys`. A node that rebooted and lost its session
self-heals on the next submit. Full algebra: [AXIOMS.md](./AXIOMS.md);
walkthrough: [docs/architecture.md](./docs/architecture.md).

---

## Layout

    tcpuxdo                  — the entrypoint wrapper (submit / list / shortcut / allow / doctor)
    server.py                — in-memory queue + axiom-checked router + ip gate   (runs on the relay)
    worker.py                — polls the queue, reports pane state, runs tmux      (runs on each node)
    client.py                — CLI submit with auto-cascade on rejection           (runs on main)
    axioms.py                — pure predicates, one family per command
    allowlist.py             — redux-style reducer + IP axioms + atomic JSON store
    allowlist_server.py      — admin TCP server: allow / block / get
    allowlist.seed.json      — initial allowed IPs (bootstrap only)
    proto.py                 — framed-JSON TCP helpers (zero deps)
    AXIOMS.md                — the formal command algebra
    setup/                   — numbered deploy scripts (00-preflight … 04-verify)
    docs/                    — architecture + deployment + onboarding
    docs/runbook/            — masked per-pane runbooks (the unmasked ones live in /runbook/, gitignored)

---

## Requirements

- `python3`, `tmux` — on the nodes (the workers shell out to tmux)
- `python3` — on the relay and on main (stdlib only, zero pip deps)
- `ssh` — on main, to deploy to the relay and nodes

```sh
# debian/ubuntu
sudo apt install python3 tmux
# arch
sudo pacman -S python tmux
```

---

## Install

```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo
cd ~/tcpuxdo
cp .env.example .env
$EDITOR .env                 # set TCPUX_HOST=your.vps.ip and the two ports — that's the core
ln -s "$PWD/tcpuxdo" ~/bin/tcpuxdo
tcpuxdo doctor               # sanity-check python/tmux, .env, relay reachability
```

`.env` is git-ignored. The repo is public; **your deployment is not.**

---

## Setup (do this once, in order)

Each script is committed, idempotent, and dispatches the real work into a **titled tmux pane** on
the target — never run ad-hoc. Source of truth for what each pane runs:
[`docs/runbook/`](./docs/runbook).

```sh
bash setup/00-preflight.sh       # check relay SSH + python/tmux on relay & nodes
bash setup/01-relay-deploy.sh    # ship the engine to the VPS, start the queue in a titled pane
bash setup/02-open-ports.sh      # open the queue/admin ports on the relay firewall
bash setup/03-node-onboard.sh    # onboard a tty node: install engine, start a worker pane
bash setup/04-verify.sh          # end-to-end: submit a no-op send-keys and watch it land
```

Run `03-node-onboard.sh` once per node. See [docs/onboard-tty-node.md](./docs/onboard-tty-node.md).

---

## Commands

| Command | Where | Does |
|---------|-------|------|
| `tcpuxdo -w NODE -p s:w:p -c 'CMD'` | main | submit `send-keys CMD` to a pane (auto-cascades if the pane is missing) |
| `tcpuxdo -s NAME -c 'CMD'` | main | same, but address the pane by a registered **shortcut** name |
| `tcpuxdo list [NODE]` | main | pretty-print nodes and their live panes (idle/busy + current cmd) |
| `tcpuxdo shortcut set NAME -w NODE -p s:w:p` | main | alias a friendly name → (node, pane) |
| `tcpuxdo allow / block / get` | main | manage the relay's IP allowlist (admin-token gated) |
| `tcpuxdo doctor` | anywhere | check deps, `.env`, relay reachability |

All config is environment variables, loaded from `.env`. See `.env.example`.

---

## Addressing a pane

A pane id is `session:window:pane` (positional). Your tmux uses `pane-base-index=1`, so the first
pane is `.1`, not `.0`. Two ways to target:

- **By id:** `tcpuxdo -w nodeA -p work:1:1 -c 'git pull'`
- **By shortcut:** register once (`tcpuxdo shortcut set claude-main -w nodeA -p work:1:1`), then
  `tcpuxdo -s claude-main -c '/compact'`.

> **Title-based addressing** (e.g. "the pane *titled* `claude`") is **not** wired in yet — the
> worker syncs `session/window/pane/current_command/pid` but not `#{pane_title}`. It's the obvious
> next feature and the natural place to hang it is the shortcut resolver. See
> [docs/architecture.md](./docs/architecture.md#roadmap).

---

## The Claude-pane bit

The worker classifies a pane as **idle** (safe to type into) when its `pane_current_command` is in
`TCPUX_IDLE_CMDS` — which ships with the shells **plus `claude`**, because Claude Code reads typed
prompts as input. So `send-keys` into a Claude Code pane is treated as a first-class, safe op, while
a pane running a build or a REPL is `busy` and the op is rejected (`SK5`). Override the set per node:

```sh
TCPUX_IDLE_CMDS="bash,zsh,fish,sh,claude,node" tcpuxdo …    # or set it in the node's .env
```

To run the worker as a **non-root `claude` user** (Claude Code refuses `--dangerously-skip-permissions`
as root), `setup/03-node-onboard.sh` provisions that user and starts the worker pane under it.

---

## Security

- The queue's submit port accepts ops from anyone who can reach it. The **IP allowlist** (`tcpuxdo
  allow <ip>`) is the gate; keep the relay behind a VPN/Tailscale/WireGuard or a cloud-firewall
  allowlist on top. A rejected source never reaches the axioms.
- `send-keys` runs as whatever user owns the pane. Treat node access as equivalent to a shell on
  that box. Don't expose a relay that fronts privileged panes to an open internet.
- `.env`, `*.token`, `*.key`, and the root-level `/runbook/` are git-ignored. Run `tcpuxdo doctor`
  and `git status` before your first deploy to confirm nothing host-specific is staged.
- The admin token (`TCPUX_ADMIN_TOKEN`) gates allowlist mutations; generate with
  `openssl rand -hex 32` and keep it only in `.env`.

---

## Naming

This repo is **`tcpuxdo`** — a staging fork of `tcpux` wearing the credpipe deployment skin. The
Python engine keeps its native `TCPUX_*` env vars and `tcpux` internals untouched, so if this
matures it can graduate to *be* `tcpux` with no engine churn — only the wrapper and docs are
tcpuxdo-branded.

## License

MIT — see [LICENSE](LICENSE).
