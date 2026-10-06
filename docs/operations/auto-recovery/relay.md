# Relay recovery contract

**Status:** partial MVP. The relay remains a queue. Laptop-initiated pinned update is supported by the shared per-host updater, but remote completion evidence and automated rollback orchestration are not.

## What is managed

The relay hosts tcpuxdo's queue server and admin service. It is a critical transport dependency, so its restart necessarily interrupts worker polling and result delivery for a bounded interval. The laptop must initiate and verify the restart using a registry target and a tracked deploy step. The relay must not decide which branch or revision is desired.

## Minimal topology

```text
relay tmux session
  tcpuxdo-relay-watch   -> tracked relay-watch.sh loop (optional if laptop dispatches one-shot)
  tcpuxdo-relay-server  -> server.py
  tcpuxdo-relay-admin   -> allowlist/admin service
  tcpuxdo-relay-state   -> read-only observer
```

The proposed watcher is distinct from queue panes, but no relay watcher or relay auto-update loop is installed by this MVP. Laptop remains responsible for deployment order. The existing SSH push path may carry a pinned update; it is not a policy engine.

## Update/recovery behavior

1. Laptop operator preflights the registry-resolved relay, transport, repository identity, clean checkout, pinned full SHA, and local deadline before dispatch.
2. Stage/execute the tracked relay update program. Preserve `.env`, allowlist data, shortcuts DB, logs, and other runtime data; update code only. Do not copy secrets into logs or run artifacts.
3. Record the old revision and operation ID durably before restart. Fetch and install only the master-selected SHA; reject dirty/divergent checkout state.
4. `setup/relay-restart.sh` requires exactly one pane with the configured server title and restarts only that pane. There is no separate relay watcher or admin restart in this MVP.
5. Laptop runs the queue RPC health probe by deadline. This probe does not establish the running relay revision; verify the relay checkout/result file through the declared push transport before declaring relay SHA healthy.
6. After queue recovery, confirm worker heartbeats resume and collect final relay/worker evidence to the master run folder. A successful SSH command or tmux respawn is only `started`, not `healthy`.
7. On failure, master observes deadline expiry and invokes the declared rollback step. Relay does not make its own rollback policy decision. Verify old revision and queue RPC, then report both deploy and rollback verdicts.

## Liveness and reporting

The implemented relay health probe establishes only that queue RPC responds. It does not verify server revision or watcher heartbeat. Laptop must verify relay checkout SHA independently; the current status RPC exposes worker metadata, not relay process metadata.

The relay can lose its return channel during restart. The laptop independently probes after restart. Result-file collection across the transport is not automated.

## Stop and recovery (future coordinator behavior)

Laptop `stop <run-id>` prevents later steps and stops only the operation started by that run; it must not casually kill the queue service and strand all workers. If the update itself hangs, the stop adapter targets the uniquely identified updater process/pane, records partial state, and leaves the last known server process intact where possible. Re-dispatch is safe under the same idempotency key. A fresh relay bootstrap must restore code from the pinned revision and preserve registered runtime configuration; no manual interactive repair is an accepted recovery path.

## Acceptance checks

- Missing/incomplete run configuration prevents the deploy step from being dispatched.
- Duplicate update delivery does not create duplicate panes or restart loops.
- Restarting queue server does not erase the operation result needed by master.
- Wrong SHA, dirty tree, ambiguous pane title, queue RPC failure, and stale deadline all fail closed.
- A relay can be rebuilt from its tracked bootstrap and master-owned registry/config without a human typing into its shell.
