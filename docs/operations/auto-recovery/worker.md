# Worker recovery contract

**Status:** partial MVP. Workers continue polling the relay. A separate titled watchdog pane is created by `setup/node-up.sh`; it restarts only a uniquely titled worker pane. Pinned code rollout is still a laptop-issued command, not a worker-side update contract.

## What is managed

A worker is `worker.py`, which polls the relay, reports tmux inventory, executes queued operations, and acknowledges results. It is not safe to update by typing into its own pane: it is normally busy, and the busy guard correctly rejects arbitrary sends. The watchdog is a separate process supervisor; rollout itself remains laptop-dispatched.

## Minimal tmux topology

```text
session tcpuxdo-worker
  pane title tcpuxdo-worker-main   -> worker.py --name <registry-name>
  pane title tcpuxdo-worker-watch  -> tracked watchdog.sh (restart only)
  pane title tcpuxdo-worker-obs    -> read-only pane/process observer (optional)
```

The watchdog must not live in `tcpuxdo-worker-main`, because respawning that pane would kill it. `setup/node-up.sh` starts it in `tcpuxdo-worker-watch`. It checks the unique exact main title and restarts only that pane when its process is dead. It does not fetch Git changes, update code, or launch `redeploy-loop.sh`. The node may use a user service to keep tmux alive, but this MVP does not install one.

## Laptop-issued update (implemented path)

The laptop resolves the selected ref to one full SHA, resolves the worker by its registry name, and dispatches `REDEPLOY_ROLE=worker REDEPLOY_SHA=<full-sha> bash setup/redeploy-watch.sh` to the named idle control pane through the existing relay poll queue. No branch tracking, worker contract poller, or fleet run ID exists in this MVP.

For a node still running the old updater, it does not read `REDEPLOY_SHA`. First merge the reviewed change into the default branch already tracked by the node. From master, run `setup/node-redeploy.sh --adopt-default <branch> <worker> <control-pane> '~/tcpuxdo'`. It dispatches only `REDEPLOY_BRANCH='<branch>' bash <repo>/setup/redeploy-watch.sh` through relay polling; the legacy tracked watcher performs its own branch pull and restart. Before dispatch, require fresh relay metadata with the expected branch and `dirty == false`; `worker.py` reports dirtiness from `git status --porcelain`. Verify the worker's newly reported revision, then use pinned dispatch. If the legacy watcher is absent or branch/cleanliness evidence is missing or mismatched, stop; use a separately reviewed preinstalled tracked bootstrap.

## Worker update/recovery loop

1. Worker continues polling the relay as before. The watchdog only revives a dead worker process.
2. Laptop pins a full SHA and dispatches the tracked updater to the idle control pane. The updater rejects dirty state and non-fast-forward changes.
3. The updater restarts only the unique worker-main pane. `worker-health.sh` compares fresh relay metadata's eight-character SHA to `git rev-parse --short=8 HEAD`.
4. The updater writes a local `.redeploy-result`; the current relay protocol does not transport this file. Laptop must independently observe fresh matching `state.meta.sha`; queued or acknowledged keystrokes are not health.

## Status contract

The local `.redeploy-result` carries status, old/requested/observed full SHA, health, role, timestamp, and error. It is not transported by relay. Relay `state.meta.sha` carries an eight-character SHA and freshness; `worker-health.sh` compares this representation safely. Queue `QUEUED` or `send-keys` acknowledgement is never health.

## Stop, duplicate delivery, and rebuild (future coordinator behavior)

Master stop is delivered through the relay as a tracked stop operation. Worker checks run ID and process/pane identity before stopping the updater's operation; it must not kill arbitrary panes or merely detach the tmux client. On stop, mark output partial and return the observed process exit. Re-dispatch of update is the recovery: same key converges; new attempt gets a new attempt number under the same run. If the machine is lost, master marks it failed at deadline and can address a replacement by registry name. Bootstrap recreates worker/watch panes and the managed checkout from tracked programs; no SSH hand-repair or reliance on node-only knowledge.

## Acceptance checks

- A dead `worker.py` process is detected and restarted without restarting/killing the watchdog.
- New worker revision is not considered live until relay observes its heartbeat before deadline.
- Duplicate request, relay outage, dirty tree, wrong SHA, missing pane, ambiguous title, restart failure, and rollback failure have distinct results.
- Master can stop a run and observe the process stop; detached work must not survive.
- Destroy/rebuild the node mid-run: master status fails on time, and redispatch to a fresh worker does not need human memory of the lost node.
