# pane: `submit` (main laptop) — the SENDER

Role: where you submit tmux ops to the queue. This is your everyday shell on main with `tcpuxdo`
on `PATH`. cwd `<repo>` (this tcpuxdo clone), `.env` filled in.

> Real per-deployment values are masked as `<…>`. The unmasked copy lives in the git-ignored
> `runbook/`.

## Commands run

```sh
tcpuxdo list                                  # what nodes/panes exist right now
tcpuxdo -w <node> -p <s:w:p> -c 'git pull'    # send-keys to a pane (cascades if missing)
tcpuxdo shortcut set <name> -w <node> -p <s:w:p>
tcpuxdo -s <name> -c '<prompt or command>'    # send-keys via shortcut (e.g. the claude pane)
```

Output of `list` per node: `<node>  (N panes, M queued)` then one line per pane with `[idle|busy]`
and the current command.

## Gotcha hit

- Addressing a pane that's mid-build returns `{"ok": false, "err": "pane busy (<cmd>)"}` — by
  design (`SK5`). Wait for it to go idle, or target a different pane.
- Pane indices are **1-based** (`pane-base-index=1`): the first pane is `<s>:<w>:1`, never `:0`.
- A bare `tcpuxdo` with no `.env` errors `missing <repo>/.env` — copy `.env.example` first.

## Equivalent repo script

```sh
bash setup/04-verify.sh <node>     # scripted end-to-end submit (a harmless echo)
```

## Notes

- `-c` text is sent followed by `Enter`. To send a literal control key sequence, send the raw token
  (the worker passes it to `tmux send-keys`).
- Submitting to a Claude Code pane is a first-class case: `claude` is in `TCPUX_IDLE_CMDS`, so the
  pane reads as idle and the prompt lands as typed input.
