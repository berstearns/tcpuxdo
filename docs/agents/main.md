# AGENT RUNBOOK — role: MAIN (your laptop / control machine)

You are an agent setting up **main**: the machine that submits tmux jobs to the queue and
administers the allowlist. Execute steps in order. Stop and report on any **Verify** failure.
Never print, echo, or commit any key marked `SECRET`.

## Inputs (from `.env`)

| Key | Required | Secret | Value |
|-----|----------|--------|-------|
| `TCPUX_HOST` | yes | no | the relay's public IP/DNS |
| `TCPUX_PORT` | yes | no | the relay's queue port (must match the relay) |
| `TCPUX_ADMIN_PORT` | for `allow`/`block` | no | the relay's admin port |
| `TCPUX_ADMIN_HOST` | for `allow`/`block` | no | set equal to `TCPUX_HOST` (admin client defaults to `127.0.0.1`, which is wrong on main) |
| `TCPUX_ADMIN_TOKEN` | for `allow`/`block` | **SECRET** | must be the **same value** set on the relay |

Submitting jobs (`tcpuxdo -w … -c …`) needs only `TCPUX_HOST`+`TCPUX_PORT`. The token is needed
**only** to mutate the allowlist.

## Preconditions

```sh
command -v python3                              # required
# relay reachable (firewall open for the queue port):
timeout 5 bash -c "</dev/tcp/${TCPUX_HOST}/${TCPUX_PORT}" && echo "queue reachable" || echo "BLOCKED — open the firewall / check TCPUX_HOST:PORT"
```

## Steps

```sh
git clone https://github.com/berstearns/tcpuxdo ~/tcpuxdo
cd ~/tcpuxdo
cp .env.example .env
# edit .env: set TCPUX_HOST, TCPUX_PORT, TCPUX_ADMIN_PORT, TCPUX_ADMIN_HOST=$TCPUX_HOST,
# and TCPUX_ADMIN_TOKEN to the SAME secret used on the relay.
ln -s "$PWD/tcpuxdo" ~/bin/tcpuxdo        # ensure ~/bin is on PATH; or use ./tcpuxdo
```

## Verify (all must pass)

```sh
# 1. deps + .env + relay reachability
./tcpuxdo doctor
# expect: ends with DOCTOR_OK

# 2. queue is reachable and answers
./tcpuxdo list
# expect: a node listing OR "(no nodes registered)" — NOT a timeout/traceback

# 3. admin token works + gate is set (adds this laptop's IP to the queue allowlist)
./tcpuxdo allow "$(curl -s ifconfig.me)"
# expect: {"ok": true, "ip": "<your-ip>", ...}

# 4. submit path works end-to-end (dummy worker → axiom verdict, proves the pipe)
./tcpuxdo -w __agent_probe__ -p s:1:1 -c 'echo probe' --no-cascade
# expect: SK1_WORKER_UNKNOWN  (this is SUCCESS — submit reached the queue and was validated)
```

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `./tcpuxdo` → `missing .env` | no `.env` | `cp .env.example .env` and fill it |
| step 2/4 → connect **timeout** | firewall not open for `TCPUX_PORT` | open the port on the relay's cloud firewall |
| submit → `N1_IP_NOT_ALLOWED` | this laptop's IP not on the gate | run step 3 (`tcpuxdo allow <ip>`) |
| `allow` → `BAD_TOKEN` | `TCPUX_ADMIN_TOKEN` ≠ relay's token | set the identical secret in both `.env`s |
| `allow` → timeout | `TCPUX_ADMIN_HOST` still `127.0.0.1`, or admin port closed | set `TCPUX_ADMIN_HOST=$TCPUX_HOST`; open `TCPUX_ADMIN_PORT` |

## Done when

`./tcpuxdo doctor` ends `DOCTOR_OK`, `./tcpuxdo list` answers, `./tcpuxdo allow` returns `ok:true`,
and the probe submit returns `SK1_WORKER_UNKNOWN`. Main is now able to dispatch — it just needs a
node to exist (see `docs/agents/tty-node.md`).

## Everyday commands (after a node exists)

```sh
./tcpuxdo list                                   # nodes + panes (idle/busy)
./tcpuxdo -w <node> -p <session:window:pane> -c '<cmd>'    # send-keys; pane index is 1-based
./tcpuxdo shortcut set <name> -w <node> -p <s:w:p>
./tcpuxdo -s <name> -c '<prompt>'                # send-keys to e.g. a Claude pane by name
```
