# AGENTS.md — operating tcpuxdo as an agent

tcpuxdo dispatches tmux commands (notably `send-keys`, including into Claude Code panes) from one
**main** machine, through a **relay** queue on a VPS, to **node** workers that execute locally.

If you are an agent setting this up, pick the doc for the role you are on and follow it top to
bottom. Each is a strict contract: **Inputs → Preconditions → Steps → Verify → Failure → Done.**

| Role | You are… | Doc |
|------|----------|-----|
| **relay** | on the VPS that holds the queue | [docs/agents/relay.md](docs/agents/relay.md) |
| **main** | on the laptop that submits jobs + admins the allowlist | [docs/agents/main.md](docs/agents/main.md) |
| **tty-node** | on a headless box that runs tmux/Claude and executes ops | [docs/agents/tty-node.md](docs/agents/tty-node.md) |

## Order to bring a fleet up

1. **relay** — start the queue, open its two ports.
2. **main** — point `.env` at the relay; `tcpuxdo allow <main-ip>`.
3. **tty-node** (×N) — on each node; then `tcpuxdo allow <node-egress-ip>` from main.
4. Dispatch: `tcpuxdo -w <node> -p <pane> -c '<cmd>'`.

## Rules for agents (non-negotiable)

- **Never** print, echo, log, or commit any value marked `SECRET` (only `TCPUX_ADMIN_TOKEN` is).
  Generate it with `openssl rand -hex 32`; it lives only in the git-ignored `.env`.
- All real values (relay IP, ports, token) live in `.env` (git-ignored). This repo is public; every
  doc uses placeholders. Do not write real values into any tracked file.
- The `.env` must match between **relay** and **main** for the admin token; nodes need no secret.
- Run the exact commands as written; do not improvise. Stop and report on any failed **Verify**.

## What each role needs in `.env` (keys only — set values in `.env`, never here)

- **relay:** `TCPUX_PORT`, `TCPUX_ADMIN_PORT`, `TCPUX_ADMIN_TOKEN` (SECRET); `TCPUX_HOST=0.0.0.0`.
- **main:** `TCPUX_HOST`, `TCPUX_PORT`, `TCPUX_ADMIN_PORT`, `TCPUX_ADMIN_HOST=<relay>`, `TCPUX_ADMIN_TOKEN` (SECRET, == relay's).
- **tty-node:** `TCPUX_HOST` (relay), `TCPUX_PORT`, `TCPUX_WORKER` (unique). No secret.

Prose/architecture context: [README.md](README.md), [docs/architecture.ascii](docs/architecture.ascii),
[docs/deployment.md](docs/deployment.md).
