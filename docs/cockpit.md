# The cockpit — one keypress, a remote Claude pane you can drive

`scripts/AUTO-tcx-cockpit.sh` turns "I want a Claude Code session on the other
box" into one command:

```sh
scripts/AUTO-tcx-cockpit.sh -w <worker> -s <name> -d '<remote dir>'
```

and with no flags at all it asks for those three things with rofi, the worker
list coming from **live relay state** (`tcpuxdo --op state`, parsed with `jq`).

What you end up with:

| where | what |
|---|---|
| the worker | tmux session `<name>`, one pane running `claude` in `<dir>` |
| the relay | shortcut `claude-main` → that (worker, pane) |
| `~/.cache/tcpuxdo/target` | `worker<TAB>pane` — the shared target file |
| m1 | tmux session `<name>-cockpit`, panes **`tcx-send`** and **`tcx-stream`** |

`tcx-send` sits at a shell prompt with `tcx-cli send ` already typed but **not**
executed. `tcx-stream` runs `setup/tcx-stream.sh`, which is the live view of the
remote pane. Attach with `tmux attach -t <name>-cockpit`.

This file **orchestrates and reimplements nothing**: `tcpuxdo` does the ops,
`tcx-cli` does the sending, `setup/tcx-stream.sh` does the mirroring. There is
no capture loop in the cockpit script, deliberately.

## The one command

```sh
# everything specified — the form the i3 shortcut uses
scripts/AUTO-tcx-cockpit.sh -w newlaptop -s ferret -d '~/p/ferret'

# see exactly what it would do, run nothing
scripts/AUTO-tcx-cockpit.sh -n -w newlaptop -s ferret -d '~/p/ferret'

# local cockpit only (the remote session already exists)
scripts/AUTO-tcx-cockpit.sh --no-remote -s ferret
```

`scripts/AUTO-tcx-cockpit.sh --help` is the full flag list.

## The i3 binding

The i3 config lives in **another repo** (`/home/b/p/pn/os_configs/i3/config`) and
this project does not edit it. Get the line, checked for collisions, from:

```sh
scripts/AUTO-tcx-cockpit-i3bind.sh              # the default proposal
scripts/AUTO-tcx-cockpit-i3bind.sh -k '$mod+Ctrl+Shift+c'
```

**`$mod+Ctrl+c` is already taken** — line 347 binds it to
`rofi-flashcards-claude.sh`. i3 keeps the *last* `bindsym` for a key and warns
about nothing, so pasting over it would silently kill the flashcards binding.
The free key next door is `$mod+Ctrl+Shift+c`:

```
bindsym $mod+Ctrl+Shift+c exec --no-startup-id /home/b/p/tcpuxdo/scripts/AUTO-tcx-cockpit.sh
```

Every `CONFIG` key is env-overridable, so one binding can be pinned to a box:

```
bindsym $mod+Ctrl+Shift+c exec --no-startup-id \
    TCX_COCKPIT_WORKER=newlaptop /home/b/p/tcpuxdo/scripts/AUTO-tcx-cockpit.sh
```

## Teardown

```sh
scripts/AUTO-tcx-cockpit.sh --teardown -s ferret     # kills <ferret>-cockpit
```

The **remote** session is deliberately left running — that is where your Claude
context lives, and a keybinding that can destroy it by accident is not one you
want. Kill it on the worker itself (`tmux kill-session -t ferret`) when you mean
it.

Running the cockpit twice never duplicates anything: an existing
`<name>-cockpit` with both titled panes is reused, and an existing remote
session is reused rather than recreated. A session with the cockpit's *name*
that is not a cockpit is a named error pointing at `--rebuild`, never a silent
repair.

## The one thing the protocol cannot do

The spec asked for panes with **stable titles**, `claude-main` for the Claude
pane. The remote pane cannot carry that title in any way this project can
address:

`worker.py` syncs `session / window / pane / current_command / pid` and **not**
`#{pane_title}`, so a title never reaches the relay's registry and
`send-keys -p <title>` has nothing to resolve against. The README says the same
thing in "Addressing a pane": title-based addressing is not wired in.

Making it work would mean editing `worker.py` (sync the title) and the shortcut
resolver — and this task forbids touching `worker.py`, `server.py`,
`axioms.py`, `client.py`, `proto.py`. **So no protocol change was made.**

Instead the cockpit uses the stable name the protocol *does* have: a **tcpuxdo
shortcut**. Every run sets

```sh
tcpuxdo --op shortcut-set --name claude-main --worker <w> --pane <p> --force
```

so `tcpuxdo -s claude-main -c '/compact'` and `tcx-cli` both address the pane by
a fixed name, with no engine change. If title syncing ever lands in `worker.py`,
the natural home for it is the shortcut resolver (README, roadmap) and this
script keeps working either way.

## Failure modes actually hit while building this

These are not hypothetical; each one is a bug that existed in this branch.

1. **`set-option -t "=<session>" -w` is the wrong target type.** `-t =sess`
   is a target-*session*; `set-option -w` wants a target-*window*, so it printed
   `no such window: =cockpittest-cockpit` twice per run — and because the script
   correctly runs without `set -e`, the run sailed past both errors and reported
   success. Fixed by addressing the window through the pane's `%ID`.

2. **A new pane is not ready for keystrokes.** The staged `tcx-cli send ` line
   was swallowed with no error at all: `pane_current_command` was still `mkdir`
   (a line in `.zshrc`) when the keys arrived. Fixed with a bounded wait.

3. **…and "any shell" is the wrong readiness test.** The second version waited
   for *a* shell and got `bash` — a transient child of `.zshrc` — so the
   `nocorrect` decision (constraint 4) was taken for the wrong shell. Fixed by
   waiting for tmux's own `default-shell`, twice in a row, so a short-lived
   child cannot answer for the pane.

4. **`.env` overrides your environment, so a "dead relay" test can be live.**
   `./tcpuxdo` does `set -o allexport; . .env`, so `TCPUX_PORT=1 cockpit …`
   quietly talks to the production relay. Any unreachable-relay test written
   that way passes without testing anything. The cockpit therefore takes
   `TCX_COCKPIT_HOST` / `TCX_COCKPIT_PORT` and forwards them as `client.py`
   `--host` / `--port`, where an explicit flag beats the sourced default.

5. **The collision checker had the bug it exists to catch.** Its first version
   built an ERE from the key, and in an ERE `+` is a quantifier — so `Ctrl+c`
   matched `Ctrlc`, never `Ctrl+c`, and it cheerfully reported "`$mod+Ctrl+c` is
   not bound" about a file whose line 347 binds it. Now it compares awk fields,
   never a pattern.

6. **Both registered workers are stale.** `newlaptop` last reported ~38 h ago,
   `dockertest` ~16 h ago. The registry still lists their panes, so a naive
   script happily submits ops that nobody will ever execute — which looks
   exactly like success. The cockpit refuses a worker silent longer than
   `TCX_COCKPIT_DEAD_SECS` (180 s) with `E_WORKER_DEAD`. **This is also why the
   remote half of this branch is unverified against a live worker.**

## Self-check

```sh
scripts/AUTO-tcx-cockpit-selfcheck.sh          # all modes
scripts/AUTO-tcx-cockpit-selfcheck.sh negative # prove the assertions can fail
```

Eight modes: `help`, `dry`, `badworker`, `deadrelay`, `local`, `idem`,
`teardown`, `negative`. It creates and destroys its own throwaway tmux session,
sends nothing to any remote pane, and never writes the shared target file.
