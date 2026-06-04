# pane: `tcpuxdo-queue-server` (relay VPS) — the QUEUE

Role: hold the per-node job queues and validate every op against the axioms. Session
`tcpuxdo-queue`, window `queue`, pane title `tcpuxdo-queue-server`, cwd `<remote-root>`
(default `/srv/tcpuxdo`).

> Real per-deployment values are masked as `<…>`. The unmasked copy lives in the git-ignored
> `runbook/`.

## Command run

```sh
cd <remote-root> && set -o allexport && source .env && set +o allexport && python3 server.py
```

Binds `TCPUX_HOST=0.0.0.0:<TCPUX_PORT>`. Logs each op with its axiom verdict. Sibling panes:
`tcpuxdo-queue-admin` (allowlist admin on `<TCPUX_ADMIN_PORT>`) and `tcpuxdo-queue-state`
(5s state poll).

## Gotcha hit

- `server.py` exits immediately with `TCPUX_PORT` unset if `.env` wasn't sourced into the pane.
  The `set -o allexport; source .env` prefix is mandatory — the deploy script bakes it in.
- With `TCPUX_ALLOWLIST_DB` unset the server logs `dev mode, no ip gate` and accepts everyone.
  On a public relay this must be set (the deploy `.env` points it at `<remote-root>/allowlist.json`).

## Equivalent repo script

```sh
bash setup/01-relay-deploy.sh      # from main: ship + start this pane
# or daemonize instead of a pane:
sudo systemctl enable --now tcpuxdo   # uses setup/tcpuxdo.service
```

## Notes

- The relay never runs tmux; it only queues + validates. Keystrokes happen on the nodes.
- Lock the gate right after first boot: `tcpuxdo allow <main-ip>`, `tcpuxdo allow <node-ip>`.
- Watch live state in the `tcpuxdo-queue-state` pane, or from main: `tcpuxdo list`.
