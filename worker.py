"""tcpux worker — periodically reports tmux state to server and executes queued ops.

Concurrency model: single-threaded polling loop (sync rpc calls)
Communication:     framed-JSON over TCP via proto.rpc
Cancellation:      KeyboardInterrupt / SIGINT
Shared state:      none (all state is remote on the server)

Loop:
  1. Sync local tmux state via `tmux list-panes -a -F ...`
  2. Send `tmux-panes-update` to server
  3. Poll server for one queued command
  4. Execute it against tmux (send-keys / create-*)
  5. Ack the result

Pane identifiers used by tcpux are strict triples `session:window:pane` where
`window` is the window index and `pane` is the pane index (tmux assigns both
as integers). For send-keys, the worker translates `session:window:pane` to
tmux's `-t session:window.pane`.

Busy detection: a pane is idle iff `pane_current_command` matches the user's
login shell (bash/zsh/fish/…). Any other running foreground command marks the
pane as busy, and send-keys into a busy pane is rejected.
"""
import argparse, json, os, shlex, socket, subprocess, sys, time

from proto import rpc


# Commands that count as "idle" for SK5 — i.e. send-keys is safe to dispatch
# because the foreground process is interactive and accepts keystrokes as
# input. Defaults to common shells plus `claude` (Claude Code CLI takes
# typed prompts as input). Override at runtime with TCPUX_IDLE_CMDS as a
# comma-separated list to add REPLs (`python`, `node`, `irb`, …).
IDLE_CMDS = set(filter(None, os.environ.get(
    "TCPUX_IDLE_CMDS",
    "bash,zsh,fish,sh,dash,tcsh,ksh,claude"
).split(",")))


# ── tmux wrappers ───────────────────────────────────────────────

def _tmux(*args, check=True):
    r = subprocess.run(("tmux",) + args, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {' '.join(args)}: {r.stderr.strip()}")
    return r


def list_panes():
    """Return dict[pane_id → {busy, cmd, pid}] from the current tmux server.

    `pane_id` = `session_name:window_index:pane_index` — the canonical tcpux form.
    """
    fmt = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_pid}"
    try:
        r = _tmux("list-panes", "-a", "-F", fmt, check=False)
    except FileNotFoundError:
        print("  tmux not installed", flush=True)
        return {}
    if r.returncode != 0:
        return {}
    panes = {}
    for line in r.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        s, w, p, cmd, pid = parts
        pane_id = f"{s}:{w}:{p}"
        panes[pane_id] = {"busy": cmd not in IDLE_CMDS, "cmd": cmd, "pid": pid}
    return panes


def tmux_send_keys(pane_id, cmd):
    s, w, p = pane_id.split(":", 2)
    target = f"{s}:{w}.{p}"
    _tmux("send-keys", "-t", target, cmd, "Enter")


def tmux_new_session(session):
    _tmux("new-session", "-d", "-s", session)


def tmux_new_window(session, window=None):
    if window is None:
        _tmux("new-window", "-t", session)
    else:
        _tmux("new-window", "-t", f"{session}:", "-n", window)


def tmux_split_window(session, window):
    _tmux("split-window", "-t", f"{session}:{window}")


# ── op handlers — each returns {"ok": bool, ...} ────────────────

def run_send_keys(pane_id, cmd):
    fresh = list_panes().get(pane_id)
    if not fresh:
        return {"ok": False, "err": "pane vanished"}
    if fresh["busy"]:
        return {"ok": False, "err": f"pane busy ({fresh['cmd']})"}
    try:
        tmux_send_keys(pane_id, cmd)
    except Exception as e:
        return {"ok": False, "err": str(e)}
    return {"ok": True, "pane": pane_id}


def run_create_session(session):
    try:
        tmux_new_session(session)
    except Exception as e:
        return {"ok": False, "err": str(e)}
    return {"ok": True, "session": session}


def run_create_window(session, window):
    try:
        tmux_new_window(session, window)
    except Exception as e:
        return {"ok": False, "err": str(e)}
    return {"ok": True, "window": f"{session}:{window}"}


def run_create_pane(pane_id):
    # tmux assigns pane indices — the next tmux-panes-update will reveal
    # the actually-created pane_id.
    s, w, _ = pane_id.split(":", 2)
    try:
        tmux_split_window(s, w)
    except Exception as e:
        return {"ok": False, "err": str(e)}
    return {"ok": True, "requested": pane_id, "note": "tmux auto-assigns pane index; see next update"}


HANDLERS = {
    "send-keys":      lambda c: run_send_keys(c["pane"], c["cmd"]),
    "create-session": lambda c: run_create_session(c["session"]),
    "create-window":  lambda c: run_create_window(c["session"], c["window"]),
    "create-pane":    lambda c: run_create_pane(c["pane"]),
}


# ── main loop ───────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="tcpux worker")
    ap.add_argument("--name",  default=os.environ.get("TCPUX_WORKER", socket.gethostname()))
    ap.add_argument("--host",  default=os.environ.get("TCPUX_HOST", "127.0.0.1"))
    _p = os.environ.get("TCPUX_PORT")
    ap.add_argument("--port",  type=int, default=int(_p) if _p else None)
    ap.add_argument("--poll",  type=float, default=float(os.environ.get("TCPUX_POLL",  "2")))
    ap.add_argument("--sync",  type=float, default=float(os.environ.get("TCPUX_SYNC",  "5")))
    args = ap.parse_args()
    if args.port is None:
        ap.error("--port required (or set TCPUX_PORT in env)")

    print(f"tcpux-worker '{args.name}' → {args.host}:{args.port} "
          f"(poll={args.poll}s sync={args.sync}s)", flush=True)

    last_sync = 0.0
    while True:
        try:
            now = time.time()
            if now - last_sync >= args.sync:
                panes = list_panes()
                resp = rpc(args.host, args.port,
                           {"op": "tmux-panes-update", "worker": args.name, "panes": panes})
                if not resp.get("ok"):
                    print(f"  update rejected: {resp}", flush=True)
                else:
                    print(f"  update ok, panes={resp.get('panes_seen')}", flush=True)
                last_sync = now

            resp = rpc(args.host, args.port, {"op": "poll", "worker": args.name})
            if not resp.get("ok"):
                print(f"  poll rejected: {resp}", flush=True)
                time.sleep(args.poll)
                continue

            cmd = resp.get("cmd")
            if not cmd:
                time.sleep(args.poll)
                continue

            handler = HANDLERS.get(cmd["op"])
            if not handler:
                result = {"ok": False, "err": f"unknown op {cmd['op']}"}
            else:
                print(f"  exec #{cmd['id']} {cmd['op']} {cmd}", flush=True)
                result = handler(cmd)
            rpc(args.host, args.port, {"op": "ack", "id": cmd["id"], "result": result})
            # Creating tmux objects changes state — force a sync next tick.
            if cmd["op"] in ("create-session", "create-window", "create-pane"):
                last_sync = 0.0
        except (ConnectionError, OSError, socket.timeout) as e:
            print(f"  server down: {e}, retry in 3s", flush=True)
            time.sleep(3)
        except KeyboardInterrupt:
            print("\nworker stopped")
            return


if __name__ == "__main__":
    main()
