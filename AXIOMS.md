# tcpux — command algebra

tcpux accepts **only** commands that satisfy a fixed set of axioms. Every
rejection carries a stable `err_code` so the sender can react mechanically
(usually by cascading to a construction command).

## Alphabet

    IDENT    := [A-Za-z0-9_-]+
    PANE_ID  := IDENT ":" IDENT ":" IDENT       -- session:window:pane
    WIN_ID   := IDENT ":" IDENT                 -- session:window

`session`, `window`, `pane` are strings. `window` and `pane` map to tmux
indices when the worker executes. Pane indices are assigned by tmux, not
by the sender.

## State

    STATE : WORKER_ID ⇀ { panes : PANE_ID ⇀ PaneState, last_update : ℝ }
    QUEUE : WORKER_ID ⇀ Seq⟨Command⟩
    PaneState = { busy : 𝔹, cmd : str, pid : str, logs : [..] }

A worker becomes *registered* the first time it issues
`tmux-panes-update`.

## Commands and their axioms

### U — `tmux-panes-update` (worker → server)

| # | axiom | err_code |
|---|---|---|
| U1 | `worker_id ∈ IDENT` | `U1_BAD_WORKER_ID` |
| U2 | `panes` is a dict, every key matches `PANE_ID` | `U2_PANES_NOT_DICT` / `U2_BAD_PANE_ID` |
| U3 | every value has `busy : bool` | `U3_BAD_PANE_STATE` |

Effect on success: `STATE[worker_id].panes ← panes`.

### SK — `send-keys` (client → server → queue)

| # | axiom | err_code |
|---|---|---|
| SK1 | `worker_id ∈ IDENT` and registered | `SK1_BAD_WORKER_ID` / `SK1_WORKER_UNKNOWN` |
| SK2 | `pane_id ∈ PANE_ID` (grammar) | `SK2_BAD_PANE_ID` |
| SK3 | `pane_id ∈ dom(STATE[worker_id].panes)` | `SK3_PANE_NOT_EXIST` |
| SK4 | `cmd` is a non-empty string | `SK4_BAD_CMD` |
| SK5 | `¬ STATE[worker_id].panes[pane_id].busy` | `SK5_PANE_BUSY` |

Uniqueness & unambiguity of SK3 are free: the pane set is a map keyed by
the canonical `PANE_ID`, so presence is a single dictionary lookup.

Effect on success: `QUEUE[worker_id] ← QUEUE[worker_id] · ⟨send-keys pane cmd⟩`.

### CAP — `capture-pane` (client → server → queue → ack with text)

Reads a pane's text back. Same target resolution as `send-keys` (exactly one
of `{pane, shortcut}`), but **no SK5 busy gate** — capturing a busy pane's
output is the whole point.

| # | axiom | err_code |
|---|---|---|
| CAP1 | `worker_id ∈ IDENT` and registered | `CAP1_BAD_WORKER_ID` / `CAP1_WORKER_UNKNOWN` |
| CAP2 | `pane_id ∈ PANE_ID` (grammar) | `CAP2_BAD_PANE_ID` |
| CAP3 | `pane_id ∈ dom(STATE[worker_id].panes)` | `CAP3_PANE_NOT_EXIST` |

Effect on success: `QUEUE[worker_id] ← QUEUE[worker_id] · ⟨capture-pane pane lines⟩`.
The worker runs `tmux capture-pane -p` (optionally `-S -lines`) and acks the
text into `DISPATCHED[id].result.text`; the client polls `status` to read it.

### CS — `create-session`

| # | axiom | err_code |
|---|---|---|
| CS0 | worker registered | `CS0_WORKER_UNKNOWN` |
| CS1 | `session ∈ IDENT` | `CS1_BAD_SESSION` |
| CS2 | `session ∉` existing sessions of worker | `CS2_SESSION_EXISTS` |

### CW — `create-window`

| # | axiom | err_code |
|---|---|---|
| CW0 | worker registered | `CW0_WORKER_UNKNOWN` |
| CW1 | session & window ∈ IDENT; session exists | `CW1_BAD_IDENT` / `CW1_SESSION_MISSING` |
| CW2 | `session:window ∉` existing windows | `CW2_WINDOW_EXISTS` |

### CP — `create-pane`

| # | axiom | err_code |
|---|---|---|
| CP0 | worker registered | `CP0_WORKER_UNKNOWN` |
| CP1 | `pane_id ∈ PANE_ID` | `CP1_BAD_PANE_ID` |
| CP2 | `session` exists | `CP2_SESSION_MISSING` |
| CP2 | `session:window` exists | `CP2_WINDOW_MISSING` |
| CP3 | `pane_id ∉` existing panes | `CP3_PANE_EXISTS` |

### P — `poll` (worker → server)

| # | axiom | err_code |
|---|---|---|
| P1 | `worker_id ∈ IDENT` | `P1_BAD_WORKER_ID` |

### A — `ack`

| # | axiom | err_code |
|---|---|---|
| A1 | `cmd_id` was dispatched | `A1_UNKNOWN_CMD` |

### N — network-layer ip gate (checked on every frame by the main server)

The queue server reads `TCPUX_ALLOWLIST_DB` (a JSON file maintained by
`allowlist_server.py`). Ip-gate runs before any op-specific axiom.

| # | axiom | err_code |
|---|---|---|
| N1 | db file exists | `N1_DB_MISSING` |
| N1 | db file parses + invariants hold | `N1_DB_INVALID` |
| N1 | source ip ∉ blocked | `N1_IP_BLOCKED` |
| N1 | source ip ∈ allowed | `N1_IP_NOT_ALLOWED` |

If `TCPUX_ALLOWLIST_DB` is unset the gate is disabled (dev mode) and a
warning is logged once. Production deploys must set it.

## Shortcuts (worker:pane aliases)

A small global namespace mapping a name to a (worker, pane) tuple, so
`./tcpux -w X -p Y -c '…'` can shorten to `./tcpux -s b -c '…'`.

State:

    SHORTCUTS : NAME ⇀ { worker : WORKER_ID, pane : PANE_ID, created_at : ℝ }

Persisted to `TCPUX_SHORTCUTS_DB` (atomic write, mtime-cache reload —
same lifecycle as the allowlist db). If the env var is unset, shortcuts
are in-memory only and lost on restart.

### SH — `shortcut-set`

| # | axiom | err_code |
|---|---|---|
| SH1 | name matches `[A-Za-z0-9_-]{1,32}` | `SH1_BAD_NAME` |
| SH2 | worker registered | `SH2_BAD_WORKER_ID` / `SH2_WORKER_UNKNOWN` |
| SH3 | pane matches PANE_ID and ∈ STATE[worker].panes | `SH3_BAD_PANE_ID` / `SH3_PANE_NOT_EXIST` |
| SH4 | name ∉ SHORTCUTS unless `force=true` | `SH4_NAME_TAKEN` |

Validation runs at write time only. A worker dying invalidates the
target silently — but the next `send-keys` through the shortcut hits
SK3 and fails honestly (see SK0 below).

### SHD — `shortcut-del`

| # | axiom | err_code |
|---|---|---|
| SHD1 | name ∈ SHORTCUTS | `SHD1_UNKNOWN` |

### SK0 — send-keys target resolver (precondition for SK1–5)

`send-keys` accepts either `pane` (with `worker`) or `shortcut`, never both.

| # | axiom | err_code |
|---|---|---|
| SK0a | exactly one of `{pane, shortcut}` is set | `SK0_AMBIGUOUS` / `SK0_NO_TARGET` |
| SK0b | if `shortcut` set, must ∈ SHORTCUTS | `SK0_SHORTCUT_UNKNOWN` |

After SK0, the (worker, pane) tuple is determined and SK1–5 run unchanged.

## Allowlist reducer (redux-style)

The allowlist itself is a pure reducer with two single-entrypoint actions:

    {"type": "ALLOW", "ip": "<ipv4>"}  → ensure ip ∈ allowed, ip ∉ blocked
    {"type": "BLOCK", "ip": "<ipv4>"}  → ensure ip ∈ blocked, ip ∉ allowed

Reducer axioms:

| # | axiom | err_code |
|---|---|---|
| N1 | ip matches `[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}` | `N1_BAD_IP` |
| N2 | `action.type ∈ {ALLOW, BLOCK}` | `N2_BAD_ACTION` |

Invariants re-checked after every reduce (any failure raises, never
persists stale state):

| # | invariant | err_code |
|---|---|---|
| I1 | `allowed ∩ blocked = ∅` | `I1_OVERLAP` |
| I2 | every element of `allowed ∪ blocked` satisfies N1 | `I2_BAD_IP` |

Mutations flow through `allowlist_server.py` (TCP, framed JSON). Auth is
a shared `TCPUX_ADMIN_TOKEN` compared with `hmac.compare_digest`. The
read op `get` is unauthenticated so the main server and operators can
smoke-test the db. Writes are atomic via `os.replace(tmp, db)` and the
main server's read-cache invalidates on mtime change.

## Induced rule: the cascade ladder

When a sender receives `SK3_PANE_NOT_EXIST`, the induced strategy is:

    try create-pane(pane_id)
      if CP2_WINDOW_MISSING   → create-window(session, window)
        if CW1_SESSION_MISSING → create-session(session)
      retry create-pane(pane_id)
    wait for tmux-panes-update to reflect the new pane
    retry send-keys

Each step is itself strictly axiomatic, so the cascade terminates in at
most three construction ops before the ladder is built. Because tmux
assigns pane indices, the actual created `pane_id` may differ from the
requested one; the sender must re-read state after the update.

## Design constraints

- **No coercion.** The server never "fixes up" a bad request. Every
  rejection names an axiom.
- **Single dispatch.** A command belongs to exactly one worker's queue.
- **In-memory only.** STATE and QUEUE do not persist across restarts.
  The first `tmux-panes-update` from each worker rebuilds STATE.
- **Busy-awareness is authoritative on the worker.** The server's busy
  flag is best-effort; the worker rechecks before pressing keys.
