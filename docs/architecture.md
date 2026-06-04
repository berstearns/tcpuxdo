# Architecture

tcpuxdo = the **tcpux** dispatch engine (the axiom-checked tmux command queue) wearing the
**credpipe** deployment skin (public repo, private `.env`, numbered setup, masked runbooks). This
doc visualizes how the pieces move.

## Topology

```
        main laptop                     relay (VPS)                      tty nodes ×N
   ┌───────────────────┐          ┌────────────────────────┐       ┌────────────────────────┐
   │  tcpuxdo (client)  │  submit  │  server.py             │ poll  │  worker.py             │
   │  you type ops here │ ───────► │  ┌──────────────────┐  │ ◄──── │  loop: poll → exec →   │
   │                    │  :9000   │  │ per-node queues  │  │ :9000 │        ack → report    │
   │                    │          │  │ + axiom router   │  │ ────► │                        │
   │                    │          │  │ + IP allowlist   │  │  op   │   tmux send-keys ...   │
   └───────────────────┘          │  └──────────────────┘  │       │   ┌──────────────────┐ │
                                   │  allowlist_server.py   │       │   │ claude pane (idle│ │
                                   │  :9001  (admin token)  │       │   │ → safe to type)  │ │
                                   └────────────────────────┘       │   └──────────────────┘ │
                                     dumb: never runs tmux           │   reports pane state   │
                                                                     └────────────────────────┘
```

- **main** never talks to a node directly — both are behind NAT. The relay is the meeting point.
- **The relay never runs tmux.** It only queues + validates ops. The node that owns the pane is the
  only thing that shells out to `tmux`.
- **One queue per node.** A worker registers by reporting its panes; ops addressed to it wait in its
  queue until it polls.

## One `send-keys`, end to end

```
main                          relay                              node worker
 │ tcpuxdo -w nodeA              │                                   │
 │   -p work:1:1 -c 'git pull' ─►│ check axioms SK0..SK5             │
 │                               │   SK0 target resolves?            │
 │                               │   SK1 node registered?            │
 │                               │   SK2 pane id well-formed?        │
 │                               │   SK3 pane exists in last report? │
 │                               │     └─ no ─► reject SK3_PANE_NOT_EXIST ──┐
 │                               │   SK4 cmd non-empty?              │      │
 │                               │   queue the op ──────────────────┤      │
 │                               │                                   │      │
 │                               │◄──────── poll (every TCPUX_POLL) ─┤      │
 │                               │───────── op: send-keys ──────────►│      │
 │                               │                            re-read live pane state
 │                               │                            SK5 pane busy?
 │                               │                              busy   ─► {ok:false, "pane busy"}
 │                               │                              idle / claude ─► tmux send-keys -t work:1.1
 │                               │◄──────── ack {ok:true} ───────────┤      │
 │                               │◄──────── tmux-panes-update ───────┤ (every TCPUX_SYNC)
 │◄── result ────────────────────┤                                   │
                                                                     │
   on SK3_PANE_NOT_EXIST the client cascades  ◄───────────────────────┘
```

## The cascade ladder (self-healing)

If the target pane isn't in the node's last report, the client builds the missing structure
bottom-up, each step itself axiom-checked, then retries:

```
send-keys work:1:1  ──SK3──►  create-pane work:1:1
                                  │ window missing? ──CP2──► create-window work:1
                                  │                              │ session missing? ──CW1──► create-session work
                                  │                              └─ then create-window
                                  └─ then create-pane
   (tmux auto-assigns the pane index; the worker's next report shows the real id, client retries)
```

So a node that rebooted and lost its tmux server recovers on the next submit — no manual fixup.

## The idle/busy gate (why Claude panes are special)

The worker computes, per pane:

```
busy = (pane_current_command  NOT IN  TCPUX_IDLE_CMDS)
TCPUX_IDLE_CMDS default = {bash, zsh, fish, sh, dash, tcsh, ksh, claude}
```

A pane sitting at a shell prompt — or running **`claude`**, which reads typed lines as input — is
`idle` and safe to `send-keys` into. A pane mid-`make`/`pytest`/REPL is `busy`; typing into it would
corrupt that process's stdin, so `SK5` rejects the op. This is the single rule that makes
"send a prompt to the Claude pane" safe to automate across a fleet.

## Trust boundaries

```
   [ main ] ──TCP──► [ relay :9000 submit ] ──IP allowlist (N axioms)──► [ axiom router ]
                     [ relay :9001 admin  ] ──admin token──────────────► [ allowlist mutate ]
   [ node ] ──TCP──► [ relay :9000 poll   ] ──IP allowlist──────────────► [ per-node queue ]
```

- **IP allowlist** (`tcpuxdo allow <ip>`) gates *who can reach the queue at all* — main and every
  node's egress IP must be allowed. A blocked source never reaches the axioms.
- **Admin token** gates allowlist *mutations*.
- The axioms gate *what* a permitted source may queue.

## Roadmap

- **Title-based pane addressing.** Today panes are addressed by `session:window:pane` or by a
  manually-registered shortcut. The worker's `list_panes()` format string captures
  `session/window/pane/current_command/pid` but **not** `#{pane_title}`. Adding `#{pane_title}` to
  that format and a `title → pane_id` lookup in the `SK0` target resolver would let you say
  `tcpuxdo -w nodeA --title claude -c '…'`. The shortcut machinery is the natural home for it.
- **Broader tmux verbs.** The engine does `send-keys` + `create-*`. The sibling prototype
  `simple-tcp-comm-tmux` carries a fuller dispatch table (`capture-pane`, `resize/swap/join/
  pipe/respawn-pane`, `select-pane`); port those `_build_*` builders here (each needs a matching
  server axiom) if you need to read pane output or reflow layouts remotely.
