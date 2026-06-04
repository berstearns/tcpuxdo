"""tcpux client — submit a send-keys op, cascade on rejection.

Primary flow:

    client.py -w worker1 -p sessions2:w7:p1 -c "cd ~/simple-tcp-comm && git pull"

The server enforces every axiom and, on rejection, returns a stable
`err_code`. The client knows the algebra: if the pane does not exist
(SK3), it cascades upward — create-pane → create-window → create-session
as needed — each of which is itself strictly checked server-side. Once
the ladder is built, we retry the original send-keys.

Timing: creation ops are queued for the worker, so we wait for the
worker's next `tmux-panes-update` to observe the new state before the
retry. `--wait` bounds that polling loop.
"""
import argparse, json, os, sys, time

from proto import rpc


def _state(host, port, worker):
    s = rpc(host, port, {"op": "state"})
    return s.get("state", {}).get(worker, {}).get("panes", {})


def _wait_until(host, port, worker, pred, timeout):
    """Poll worker's pane set until `pred(panes)` is truthy or deadline hits."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred(_state(host, port, worker)):
            return True
        time.sleep(1)
    return False


def _wait_for_pane(host, port, worker, pane_id, timeout):
    return _wait_until(host, port, worker, lambda panes: pane_id in panes, timeout)


def _wait_for_window(host, port, worker, session, window, timeout):
    prefix = f"{session}:{window}:"
    def pred(panes): return any(p.startswith(prefix) for p in panes)
    return _wait_until(host, port, worker, pred, timeout)


def _wait_for_session(host, port, worker, session, timeout):
    prefix = f"{session}:"
    def pred(panes): return any(p.startswith(prefix) for p in panes)
    return _wait_until(host, port, worker, pred, timeout)


def cascade_create(host, port, worker, pane_id, wait):
    """Build session → window → pane until `pane_id` is present in worker state.

    Tmux's `new-session` / `new-window` auto-create a default pane at
    window:0 pane:0, so after each construction step we re-check whether
    the target pane is already present (then we're done) before falling
    through to the next construction op.
    """
    session, window, _pane = pane_id.split(":", 2)

    if pane_id in _state(host, port, worker):
        return {"ok": True, "note": "pane already present"}

    r = rpc(host, port, {"op": "create-pane", "worker": worker, "pane": pane_id})
    if r.get("ok"):
        print(f"  create-pane queued #{r['id']}")
        return r

    code = r.get("err_code", "")

    if code == "CP2_SESSION_MISSING":
        rs = rpc(host, port, {"op": "create-session", "worker": worker, "session": session})
        if not rs.get("ok") and rs.get("err_code") != "CS2_SESSION_EXISTS":
            return rs
        print(f"  create-session queued #{rs.get('id', '-')}")
        if not _wait_for_session(host, port, worker, session, wait):
            return {"ok": False, "err_code": "TIMEOUT",
                    "hint": f"session {session} did not appear in {wait}s"}
        if pane_id in _state(host, port, worker):
            return {"ok": True, "note": "satisfied by default pane of new session"}
        code = "CP2_WINDOW_MISSING"

    if code == "CP2_WINDOW_MISSING":
        rw = rpc(host, port, {"op": "create-window", "worker": worker,
                              "session": session, "window": window})
        if not rw.get("ok") and rw.get("err_code") != "CW2_WINDOW_EXISTS":
            return rw
        print(f"  create-window queued #{rw.get('id', '-')}")
        if not _wait_for_window(host, port, worker, session, window, wait):
            return {"ok": False, "err_code": "TIMEOUT",
                    "hint": f"window {session}:{window} did not appear in {wait}s"}
        if pane_id in _state(host, port, worker):
            return {"ok": True, "note": "satisfied by default pane of new window"}

    rp = rpc(host, port, {"op": "create-pane", "worker": worker, "pane": pane_id})
    if rp.get("ok") or rp.get("err_code") == "CP3_PANE_EXISTS":
        return {"ok": True, "id": rp.get("id"), "note": rp.get("err_code")}
    return rp


def send_keys(host, port, worker, pane, cmd, cascade, wait):
    msg = {"op": "send-keys", "worker": worker, "pane": pane, "cmd": cmd}
    r = rpc(host, port, msg)
    if r.get("ok"):
        print(f"send-keys queued #{r['id']}")
        return r
    code = r.get("err_code")
    print(f"rejected: {code} — {r.get('hint')}")
    if code == "SK3_PANE_NOT_EXIST" and cascade:
        print(f"cascading to create-pane for {pane}…")
        cr = cascade_create(host, port, worker, pane, wait)
        if not cr.get("ok"):
            print(f"  cascade failed: {cr}")
            return cr
        print(f"  cascade enqueued; waiting up to {wait}s for {pane}…")
        if not _wait_for_pane(host, port, worker, pane, wait):
            # tmux auto-assigns pane index so exact pane_id may not match.
            print(f"  pane {pane} did not appear (tmux auto-assigns pane index).")
            print(f"  current panes for {worker}:")
            for pid in sorted(_state(host, port, worker)):
                print(f"    {pid}")
            return {"ok": False, "err_code": "CASCADE_INDEX_MISMATCH",
                    "hint": "created pane but index did not match — retry with an existing pane id"}
        print(f"  retrying send-keys…")
        return rpc(host, port, msg)
    return r


def main():
    ap = argparse.ArgumentParser(description="tcpux client")
    ap.add_argument("-w", "--worker", help="target worker id (or use -s)")
    ap.add_argument("-p", "--pane",   help="target pane (session:window:pane)")
    ap.add_argument("-s", "--shortcut", help="shortcut name resolving to (worker, pane)")
    ap.add_argument("-c", "--cmd",    help="command to send-keys into the pane")
    ap.add_argument("-n", "--name",   help="shortcut name for shortcut-{set,del}")
    ap.add_argument("--force", action="store_true", help="overwrite existing shortcut on -set")
    ap.add_argument("--host",  default=os.environ.get("TCPUX_HOST", "127.0.0.1"))
    _p = os.environ.get("TCPUX_PORT")
    ap.add_argument("--port",  type=int, default=int(_p) if _p else None)
    ap.add_argument("--no-cascade", action="store_true",
                    help="disable auto-cascade to create-pane on SK3 rejection")
    ap.add_argument("--wait",  type=float, default=30.0,
                    help="seconds to wait for created panes to appear")
    ap.add_argument("--op",    choices=["send-keys", "create-pane", "create-window",
                                         "create-session", "state", "status",
                                         "shortcut-set", "shortcut-del", "shortcut-list"],
                    default="send-keys")
    ap.add_argument("--session", help="session id for create-session / create-window")
    ap.add_argument("--window",  help="window id for create-window")
    ap.add_argument("--id",      type=int, help="command id for --op status")
    args = ap.parse_args()
    if args.port is None:
        ap.error("--port required (or set TCPUX_PORT in env)")

    if args.op == "send-keys":
        if not args.cmd:
            ap.error("--cmd required for send-keys")
        if args.shortcut and (args.worker or args.pane):
            # Forward both fields so the server's SK0_AMBIGUOUS axiom fires —
            # the server is the source of truth on target resolution.
            r = rpc(args.host, args.port,
                    {"op": "send-keys", "shortcut": args.shortcut,
                     "worker": args.worker, "pane": args.pane, "cmd": args.cmd})
        elif args.shortcut:
            # Shortcut-only path. Cascade is skipped: a shortcut IS the
            # contract — if (worker, pane) is stale, fix the shortcut, don't
            # silently rebuild a window-pane elsewhere.
            r = rpc(args.host, args.port,
                    {"op": "send-keys", "shortcut": args.shortcut, "cmd": args.cmd})
        else:
            if not args.worker or not args.pane:
                ap.error("--worker and --pane (or --shortcut) required for send-keys")
            r = send_keys(args.host, args.port, args.worker, args.pane, args.cmd,
                          cascade=not args.no_cascade, wait=args.wait)
    elif args.op == "create-pane":
        r = rpc(args.host, args.port,
                {"op": "create-pane", "worker": args.worker, "pane": args.pane})
    elif args.op == "create-window":
        r = rpc(args.host, args.port,
                {"op": "create-window", "worker": args.worker,
                 "session": args.session, "window": args.window})
    elif args.op == "create-session":
        r = rpc(args.host, args.port,
                {"op": "create-session", "worker": args.worker, "session": args.session})
    elif args.op == "state":
        r = rpc(args.host, args.port, {"op": "state"})
    elif args.op == "status":
        r = rpc(args.host, args.port, {"op": "status", "id": args.id})
    elif args.op == "shortcut-set":
        if not args.name or not args.worker or not args.pane:
            ap.error("--name, --worker, --pane required for shortcut-set")
        r = rpc(args.host, args.port,
                {"op": "shortcut-set", "name": args.name,
                 "worker": args.worker, "pane": args.pane, "force": args.force})
    elif args.op == "shortcut-del":
        if not args.name:
            ap.error("--name required for shortcut-del")
        r = rpc(args.host, args.port, {"op": "shortcut-del", "name": args.name})
    elif args.op == "shortcut-list":
        r = rpc(args.host, args.port, {"op": "shortcut-list"})
    else:
        r = {"ok": False, "err": "unknown op"}

    print(json.dumps(r, indent=2, default=str))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
