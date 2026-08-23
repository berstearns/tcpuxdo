# The cockpit's semantic domain

> **This document is POST-HOC.** It was written after
> `scripts/AUTO-tcx-cockpit.sh` was implemented, not before it. Maguire's rule
> `00-design-the-semantic-domain-before-code.md` is about *ordering* — the
> algebra is committed before the bodies — so writing this now does **not** make
> the cockpit compliant with R1, and this file does not claim it does. See
> **Conformance** at the bottom for the honest scorecard.
>
> What it is for: the algebra was latent in the code and in the self-check all
> along, and never written down. Naming it exposes two real gaps (below) and
> gives stage 3 something to be designed *against* rather than after.

## The domain

Five types. None of them is "a string", even though bash stores all of them as
strings — that gap is the subject of the conformance section.

| Type | What a value *means* | Not to be confused with |
|---|---|---|
| `Worker` | a tcpuxdo node that is registered **and has reported recently** | its name; a name in the registry that has gone silent |
| `RemotePane` | a pane on one `Worker` that the axioms will accept keystrokes for | a `session:window:pane` string |
| `Target` | the fleet-wide "where do sends go" pointer. There is exactly **one**, and three other programs read it | the path of the file that stores it |
| `Cockpit` | a local two-pane view — one pane to type in, one mirroring a `Target` | a tmux session name |
| `Plan` | what a run *would* do, as a value | the text a dry run happens to print |

## The vocabulary

Closed set. Signatures in the domain, with the bash function that inhabits each.

**Build**

```
worker        :: Name -> Registry -> Worker          -- validate_worker
                 -- partial: E_UNKNOWN_WORKER | E_WORKER_DEAD | E_RELAY_UNREACHABLE
remoteSession :: Worker -> SessionName -> RemotePane -- remote_half (create-or-reuse)
cockpit       :: SessionName -> Cockpit              -- local_half  (create-or-reuse)
```

**Combine**

```
launch  :: RemoteCommand -> RemotePane -> RemotePane -- the send-keys step
aim     :: RemotePane -> Target                      -- save_target
bind    :: Target -> Cockpit -> Cockpit              -- the stream pane follows Target
```

**Observe**

```
plan     :: Cockpit -> Plan       -- what --dry-run computes
render   :: Plan -> Text          -- what --dry-run prints
describe :: Cockpit -> Text       -- report()
teardown :: Cockpit -> ()         -- teardown_local
```

`Registry` is an input, not a member of the algebra: it is the relay's live
state, and the cockpit only reads it.

## The laws — and where each one is already checked

This is the payoff. Every law below was already an assertion in
`AUTO-tcx-cockpit-selfcheck.sh` before this document existed. The algebra was
being tested; it just had no name.

| # | Law | Checked by |
|---|---|---|
| L1 | `cockpit s . cockpit s ≡ cockpit s` | selfcheck `idem` |
| L2 | `render (plan c)` names exactly the effects `run c` performs | selfcheck `dry` (**partially** — see gaps) |
| L3 | `cockpit s` does not change `Target` | selfcheck `local` ("target file left untouched") |
| L4 | `launch c (launch c p) ≡ launch c p` | **nothing** — see gaps |
| L5 | `teardown . cockpit ≡ id`, and `teardown . teardown ≡ teardown` | selfcheck `teardown` |
| L6 | `remoteSession w s . remoteSession w s ≡ remoteSession w s` | **nothing** — needs a live worker |
| L7 | every partial constructor fails with a *named* error, never a silent value | selfcheck `badworker`, `deadrelay`, and the `E_BAD_SESSION` case |

### Gap 1 — L4 is implemented and never tested

`remote_half` skips the launch when the pane's `cmd` is already `claude`. That
is L4, and it is load-bearing: without it a second run types
`cd … && claude` *into* a live Claude prompt. No self-check case covers it,
because exercising it needs a registry in which the pane reports `cmd=claude`,
and the harness has no way to inject registry state.

### Gap 2 — L2 is asserted one-sided

The `dry` mode proves the preview *contains* the expected argv and that nothing
was created. It never compares the preview against what a real run actually
does. The one divergence found this session (the missing `nocorrect` prefix)
was caught by eye, not by that assertion.

## Conformance

```
SEMANTIC-DOMAIN-FIRST COMPLIANCE  (scripts/AUTO-tcx-cockpit.sh)
- Abstraction spec committed before impl: [x] NO  -> this file is commit 11 of 12;
                                                     the bodies landed in commits 1-6
- Public operations enumerated up front:  [x] NO  -> wait_for_shell was added
                                                     mid-debug, inside an unrelated fix
- Signatures phrased in the domain:       [x] NO  -> pane_by_title returns a tmux %ID;
                                                     session_panes returns "s:w:p" strings
- No raw-code escape primitive:           [x] ONE -> `-d PATH` was interpolated
                                                     unbounded into a remote shell command
                                                     (fixed in the next commit)
- Decomposition composes algebra ops:     [~] PARTLY -> main() sequences effects over
                                                     global state; it does not compose values
```

**Four of five fail.** Three of those four are permanent for this component:

- **R1 is an ordering property.** It cannot be repaired by writing this file
  later. The only honest fix is that the *next* component gets its spec first.
- **R2** is likewise historical.
- **R3** is a real constraint of the language. Bash has no opaque types: every
  value here is a string, and a discipline of "treat `%ID` as opaque" is a
  convention a reviewer must enforce, not something the interpreter checks. The
  cockpit does hold that convention in one place — it never addresses a pane by
  `session:window.index` — but `pane_by_title` handing back a raw `%ID` is a
  representation leak by Maguire's definition, and calling it anything else
  would be dressing it up.

**R4 was a real, fixable defect and is the one thing this rule actually caught
in working code.** `-d PATH` went straight into
`-c "cd ${CONFIG[dir]} && ${CONFIG[claude_cmd]}"`, a command string executed on
the remote worker. `-d '~ && curl … | sh'` would have run. That is precisely the
"general-purpose escape into raw code" R4 forbids: an operation whose nominal
domain is *a directory* whose actual domain is *arbitrary shell*. It is bounded
by a path grammar in the following commit.

This is not a privilege escalation — the whole system exists to type into live
terminals, and the README says the blast radius is "whatever that pane can do".
It is an **unbounded primitive**, which is a design defect whether or not it is
also a security one.

## What this means for stage 3

Write the domain first. For the next component that is one short file: the
types, the vocabulary, the laws — and then check each law has a test *before*
writing the body that satisfies it. Doing that here would have surfaced Gap 1
and Gap 2 as missing tests instead of as findings in a document written
afterwards.
