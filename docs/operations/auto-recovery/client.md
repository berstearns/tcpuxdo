# Client recovery contract

**Status:** partial MVP. Client updates are a laptop-invoked one-shot in a clean managed checkout. No permanent watcher, master journal, or automatic resume is implemented.

## What is managed

The client role is the laptop-side tcpuxdo CLI, cockpit, and any persistent local controller needed for a fleet run. These have different lifecycles: a CLI invoked on demand needs no daemon, while a long-running cockpit or orchestration process may need a supervisor. Do not create a permanent updater pane just for symmetry. The master itself should only auto-restart when a durable journal and independent local supervisor can resume it safely.

## Minimal topology

```text
local tmux session (or existing user service)
  tcpuxdo-client-watch  -> tracked client-watch.sh loop
  tcpuxdo-client-main   -> optional long-lived cockpit/controller
```

The watch pane is optional for CLI-only installations. It must not be the only copy of a master operation that is in progress. A local user service can keep the watcher alive across terminal closure; tmux is the visible diagnostic and operator control surface. No privileged daemon is needed for ordinary user-owned CLI work.

## Update/recovery behavior

1. Laptop operator resolves the selected ref to a full SHA and invokes `REDEPLOY_ROLE=client REDEPLOY_SHA=<sha> bash setup/redeploy-watch.sh` in a dedicated clean deployment checkout.
2. The updater checks tracked, staged, and non-ignored untracked worktree state, fetches the exact SHA, rejects non-fast-forward changes, and atomically records old/requested/observed SHA and health under `.git/tcpuxdo-redeploy/` (override with `REDEPLOY_RESULT`). Its lock is also under Git metadata by default.
3. It does not guess target or branch. Branch tracking is unsupported; a full pinned SHA is required.
4. It checks out only the requested SHA using fast-forward-only rules. Dirty or divergent state is a hard error, not an instruction to stash/reset.
5. If a long-lived client process exists, restart only its uniquely titled pane/process. Do not restart the watcher that performed the update. If the CLI is invocation-only, simply use the new revision on the next invocation.
6. Client health is local checkout/CLI doctor when available. Relay reachability should be checked separately by the laptop before any fleet-success verdict.
7. Return a structured status to the master run folder; never call local launch success a fleet success until every selected target passes its own health gate.

## Liveness and state

The result file includes status, old/requested/observed SHA, role, health, timestamp, and error. It is local evidence, not a durable master journal, and no periodic client heartbeat is implemented.

The CLI-only client has no automatic update loop. `setup/redeploy-loop.sh` is a legacy wrapper, is not installed or started by bootstrap, and does not select or discover a desired version.

## Stop, retry, and rollback

`stop <run-id>` cancels the client's orchestration loop and its child remote steps through their registered transports; it must not kill the independent recovery supervisor or delete the journal. Re-dispatch uses the same idempotency key. Rollback restores the previous client SHA only after verifying the checkout belongs to the managed deployment copy; it must not mutate the developer's working tree. If the master binary restarts, status resumes from the journal rather than starting a second rollout.

## Acceptance checks

- CLI-only mode works without an always-running updater pane.
- Kill/restart the cockpit process while a run is active: journal recovery does not duplicate a remote step.
- Dirty developer checkout blocks deployment and remains untouched.
- A simulated relay outage is reported as `ERR`/failed at deadline, never as a healthy client.
- Local rollback and relaunch are observable, and logs/results are collected under the master run folder.
