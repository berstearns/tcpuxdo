"""tcpux server — strict axiom-checked tmux command queue.

Concurrency model: asyncio
Communication:     in-memory dicts/deques (STATE, QUEUE, DISPATCHED)
Cancellation:      KeyboardInterrupt at top-level asyncio.run
Shared state:      STATE/QUEUE/DISPATCHED — owned by the single event-loop
                   task; every op handler runs to completion between awaits

State is kept entirely in memory:

    STATE[worker_id] = {
        "last_update": float,
        "panes": {pane_id: {"busy": bool, "cmd": str, "ts": float, "logs": []}}
    }

    QUEUE[worker_id] = deque of pending commands (FIFO)
    DISPATCHED[cmd_id] = {"worker": ..., "op": ..., "result": ...}

Every incoming op is routed to the matching axiom check in `axioms.py`.
On success the op either mutates STATE (tmux-panes-update) or gets
enqueued for the worker. On failure the server responds with a stable
error code so the sender can cascade programmatically.
"""
import asyncio, itertools, json, os, time
from collections import deque

import axioms, allowlist
from proto import serve


def _req_env(name):
    v = os.environ.get(name)
    if not v:
        raise SystemExit(f"required env var {name} not set — see deploy/.env")
    return v


HOST = os.environ.get("TCPUX_HOST", "0.0.0.0")
PORT = int(_req_env("TCPUX_PORT"))
ALLOWLIST_DB  = os.environ.get("TCPUX_ALLOWLIST_DB",  "")
SHORTCUTS_DB  = os.environ.get("TCPUX_SHORTCUTS_DB",  "")

STATE       = {}   # worker_id → worker record
QUEUE       = {}   # worker_id → deque[command]
DISPATCHED  = {}   # cmd_id    → {"worker","op","result"}
SHORTCUTS   = {}   # name      → {"worker","pane","created_at"}
_ID_COUNTER = itertools.count(1)


# ── Shortcuts persistence (atomic write, mtime-cache reload) ─────
# Mirrors the allowlist file lifecycle: on every mutation we write the
# whole dict atomically; on every read we reload only if the file's
# mtime changed. If TCPUX_SHORTCUTS_DB is unset, shortcuts are
# in-memory only (lost on restart).

_SC_MTIME = [None]


def _shortcuts_load():
    if not SHORTCUTS_DB or not os.path.isfile(SHORTCUTS_DB):
        return
    try:
        mt = os.path.getmtime(SHORTCUTS_DB)
    except OSError:
        return
    if _SC_MTIME[0] == mt:
        return
    with open(SHORTCUTS_DB) as f:
        data = json.load(f)
    SHORTCUTS.clear()
    SHORTCUTS.update(data.get("shortcuts", {}))
    _SC_MTIME[0] = mt


def _shortcuts_save():
    if not SHORTCUTS_DB:
        return
    os.makedirs(os.path.dirname(SHORTCUTS_DB) or ".", exist_ok=True)
    tmp = SHORTCUTS_DB + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"shortcuts": SHORTCUTS, "updated_at": time.time()},
                  f, indent=2, sort_keys=True)
    os.replace(tmp, SHORTCUTS_DB)
    try: _SC_MTIME[0] = os.path.getmtime(SHORTCUTS_DB)
    except OSError: pass


# ── Colors + log ────────────────────────────────────────────────
C = {
    "reset": "\033[0m", "dim": "\033[2m", "bold": "\033[1m",
    "red": "\033[91m", "green": "\033[92m", "yellow": "\033[93m",
    "blue": "\033[94m", "magenta": "\033[95m", "cyan": "\033[96m",
}
OP_COLORS = {
    "tmux-panes-update": "blue", "send-keys": "green", "poll": "cyan",
    "ack": "magenta", "create-session": "yellow", "create-window": "yellow",
    "create-pane": "yellow", "state": "dim",
    "shortcut-set": "magenta", "shortcut-del": "magenta", "shortcut-list": "dim",
}


def _ts(): return time.strftime("%H:%M:%S")


def log(level, op, msg, addr=""):
    color = C.get(OP_COLORS.get(op, "reset"), C["reset"])
    lvl = {"INF": C["green"], "WRN": C["yellow"], "ERR": C["red"]}.get(level, C["reset"])
    src = f" {C['dim']}← {addr}{C['reset']}" if addr else ""
    print(f"{C['dim']}{_ts()}{C['reset']} {lvl}{level}{C['reset']} "
          f"{color}{C['bold']}{op:>18}{C['reset']} {msg}{src}", flush=True)


def log_startup():
    print(f"""
{C['cyan']}{C['bold']}╔══════════════════════════════════════════╗
║         TCPUX — tmux command queue       ║
╚══════════════════════════════════════════╝{C['reset']}
  {C['green']}●{C['reset']} Host: {C['bold']}{HOST}{C['reset']}
  {C['green']}●{C['reset']} Port: {C['bold']}{PORT}{C['reset']}
  {C['green']}●{C['reset']} PID:  {C['bold']}{os.getpid()}{C['reset']}
  {C['dim']}  strict axiom mode — waiting for workers...{C['reset']}
""", flush=True)


# ── Helpers ─────────────────────────────────────────────────────

def _reject(code, hint, op, addr):
    log("WRN", op, f"{C['red']}reject {code}{C['reset']} {C['dim']}{hint}{C['reset']}", addr)
    return {"ok": False, "err_code": code, "hint": hint}


def _next_id():
    return next(_ID_COUNTER)


def _enqueue(worker_id, op, **fields):
    cid = _next_id()
    cmd = {"id": cid, "op": op, **fields}
    QUEUE.setdefault(worker_id, deque()).append(cmd)
    DISPATCHED[cid] = {"worker": worker_id, "op": op, "result": None}
    return cmd


# ── Network-layer axiom: IP allowlist ───────────────────────────
# Reads the db fresh on every connect (re-reads only when the file's
# mtime changes, so the cost is an mtime stat per frame). If the env
# var is unset we log once and pass everything — dev mode.

_AL_CACHE = {"mtime": None, "state": None, "warned": False}


def _ip_gate(addr):
    """Return None if the remote ip is allowed, else an (err_code, hint) pair."""
    if not ALLOWLIST_DB:
        if not _AL_CACHE["warned"]:
            log("WRN", "gate", f"{C['yellow']}TCPUX_ALLOWLIST_DB unset — dev mode, no ip gate{C['reset']}")
            _AL_CACHE["warned"] = True
        return None
    ip = addr.split(":", 1)[0] if addr else ""
    try:
        mt = os.path.getmtime(ALLOWLIST_DB)
    except OSError:
        return ("N1_DB_MISSING", f"allowlist db {ALLOWLIST_DB} not readable")
    if _AL_CACHE["mtime"] != mt:
        try:
            _AL_CACHE["state"] = allowlist.load(ALLOWLIST_DB)
            _AL_CACHE["mtime"] = mt
        except Exception as e:
            return ("N1_DB_INVALID", f"allowlist db invalid: {e}")
    st = _AL_CACHE["state"]
    if allowlist.is_blocked(st, ip):
        return ("N1_IP_BLOCKED", f"ip {ip} is on the blocklist")
    if not allowlist.is_allowed(st, ip):
        return ("N1_IP_NOT_ALLOWED", f"ip {ip} not on allowlist")
    return None


# ── Per-op handlers ─────────────────────────────────────────────

def _op_panes_update(msg, addr):
    op = "tmux-panes-update"
    worker_id = msg.get("worker")
    panes     = msg.get("panes", {})
    ok, code, hint = axioms.check_update(worker_id, panes)
    if not ok: return _reject(code, hint, op, addr)
    rec = STATE.setdefault(worker_id, {"panes": {}, "last_update": 0.0})
    prev = rec["panes"]
    merged = {}
    for pid, pst in panes.items():
        base = prev.get(pid, {"logs": []})
        base.update(pst)
        base.setdefault("logs", [])
        merged[pid] = base
    rec["panes"] = merged
    rec["last_update"] = time.time()
    log("INF", op, f"worker {C['bold']}{worker_id}{C['reset']} "
                   f"panes={C['cyan']}{len(merged)}{C['reset']}", addr)
    return {"ok": True, "panes_seen": len(merged)}


def _op_send_keys(msg, addr):
    op = "send-keys"
    cmd = msg.get("cmd")
    _shortcuts_load()
    # Resolve target — either direct (worker, pane) or via shortcut name.
    worker_id, pane_id, (rok, rcode, rhint) = axioms.resolve_send_keys_target(SHORTCUTS, msg)
    if not rok:
        return _reject(rcode, rhint, op, addr)
    via = f" {C['dim']}(via {msg.get('shortcut')!r}){C['reset']}" if msg.get("shortcut") else ""
    ok, code, hint = axioms.check_send_keys(STATE, worker_id, pane_id, cmd)
    if not ok: return _reject(code, hint, op, addr)
    pane = STATE[worker_id]["panes"][pane_id]
    if pane.get("busy"):
        return _reject("SK5_PANE_BUSY",
                       f"pane {pane_id} is busy with {pane.get('cmd','?')}",
                       op, addr)
    c = _enqueue(worker_id, op, pane=pane_id, cmd=cmd)
    log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} → "
                   f"{C['cyan']}{worker_id}{C['reset']}/{pane_id}{via} "
                   f"{C['dim']}{cmd[:50]}{C['reset']}", addr)
    return {"ok": True, "id": c["id"]}


def _op_create_session(msg, addr):
    op = "create-session"
    worker_id = msg.get("worker")
    session   = msg.get("session")
    ok, code, hint = axioms.check_create_session(STATE, worker_id, session)
    if not ok: return _reject(code, hint, op, addr)
    c = _enqueue(worker_id, op, session=session)
    log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{session}", addr)
    return {"ok": True, "id": c["id"]}


def _op_create_window(msg, addr):
    op = "create-window"
    worker_id = msg.get("worker")
    session   = msg.get("session")
    window    = msg.get("window")
    ok, code, hint = axioms.check_create_window(STATE, worker_id, session, window)
    if not ok: return _reject(code, hint, op, addr)
    c = _enqueue(worker_id, op, session=session, window=window)
    log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{session}:{window}", addr)
    return {"ok": True, "id": c["id"]}


def _op_create_pane(msg, addr):
    op = "create-pane"
    worker_id = msg.get("worker")
    pane_id   = msg.get("pane")
    ok, code, hint = axioms.check_create_pane(STATE, worker_id, pane_id)
    if not ok: return _reject(code, hint, op, addr)
    c = _enqueue(worker_id, op, pane=pane_id)
    log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} {worker_id}/{pane_id}", addr)
    return {"ok": True, "id": c["id"]}


def _op_poll(msg, addr):
    op = "poll"
    worker_id = msg.get("worker")
    ok, code, hint = axioms.check_poll(worker_id)
    if not ok: return _reject(code, hint, op, addr)
    q = QUEUE.get(worker_id)
    if not q:
        return {"ok": True, "cmd": None}
    c = q.popleft()
    log("INF", op, f"{C['bold']}#{c['id']}{C['reset']} → "
                   f"{C['cyan']}{worker_id}{C['reset']} {c['op']}", addr)
    return {"ok": True, "cmd": c}


def _op_ack(msg, addr):
    op = "ack"
    cmd_id = msg.get("id")
    ok, code, hint = axioms.check_ack(DISPATCHED, cmd_id)
    if not ok: return _reject(code, hint, op, addr)
    DISPATCHED[cmd_id]["result"] = msg.get("result")
    status = "ok" if (msg.get("result") or {}).get("ok") else "err"
    color = C["green"] if status == "ok" else C["red"]
    log("INF", op, f"{C['bold']}#{cmd_id}{C['reset']} → {color}{status}{C['reset']}", addr)
    return {"ok": True}


def _op_state(msg, addr):
    return {"ok": True, "state": STATE, "queue": {w: list(q) for w, q in QUEUE.items()}}


def _op_status(msg, addr):
    cmd_id = msg.get("id")
    d = DISPATCHED.get(cmd_id)
    if not d: return _reject("ST1_UNKNOWN", f"cmd {cmd_id} unknown", "status", addr)
    return {"ok": True, **d}


# ── Shortcut ops (set / del / list) ─────────────────────────────

def _op_shortcut_set(msg, addr):
    op = "shortcut-set"
    _shortcuts_load()
    name      = msg.get("name")
    worker_id = msg.get("worker")
    pane_id   = msg.get("pane")
    force     = bool(msg.get("force", False))
    ok, code, hint = axioms.check_shortcut_set(STATE, SHORTCUTS, name, worker_id, pane_id, force)
    if not ok: return _reject(code, hint, op, addr)
    overwriting = name in SHORTCUTS
    SHORTCUTS[name] = {"worker": worker_id, "pane": pane_id, "created_at": time.time()}
    _shortcuts_save()
    verb = "overwrote" if overwriting else "set"
    log("INF", op, f"{verb} {C['bold']}{name}{C['reset']} → "
                   f"{C['cyan']}{worker_id}{C['reset']}/{pane_id}", addr)
    return {"ok": True, "name": name, "shortcut": SHORTCUTS[name]}


def _op_shortcut_del(msg, addr):
    op = "shortcut-del"
    _shortcuts_load()
    name = msg.get("name")
    ok, code, hint = axioms.check_shortcut_del(SHORTCUTS, name)
    if not ok: return _reject(code, hint, op, addr)
    removed = SHORTCUTS.pop(name)
    _shortcuts_save()
    log("INF", op, f"removed {C['bold']}{name}{C['reset']} "
                   f"{C['dim']}(was → {removed['worker']}/{removed['pane']}){C['reset']}", addr)
    return {"ok": True, "name": name, "was": removed}


def _op_shortcut_list(msg, addr):
    _shortcuts_load()
    return {"ok": True, "shortcuts": SHORTCUTS}


OPS = {
    "tmux-panes-update": _op_panes_update,
    "send-keys":         _op_send_keys,
    "create-session":    _op_create_session,
    "create-window":     _op_create_window,
    "create-pane":       _op_create_pane,
    "poll":              _op_poll,
    "ack":               _op_ack,
    "state":             _op_state,
    "status":            _op_status,
    "shortcut-set":      _op_shortcut_set,
    "shortcut-del":      _op_shortcut_del,
    "shortcut-list":     _op_shortcut_list,
}


# ── Route ───────────────────────────────────────────────────────

async def route(msg, addr):
    gate = _ip_gate(addr)
    if gate is not None:
        code, hint = gate
        return _reject(code, hint, msg.get("op", "???"), addr)
    op = msg.get("op", "")
    handler = OPS.get(op)
    if handler is None:
        return _reject("UNKNOWN_OP", f"unknown op {op!r}", op or "???", addr)
    return handler(msg, addr)


def _evt(kind, **kv):
    if kind == "connect":
        print(f"{C['dim']}{_ts()}{C['reset']} {C['green']}CON{C['reset']} "
              f"{C['dim']}← {kv.get('addr','?')}{C['reset']}", flush=True)
    else:
        print(f"{C['dim']}{_ts()}{C['reset']} {C['yellow']}DIS{C['reset']} "
              f"{C['dim']}← {kv.get('addr','?')}{C['reset']}", flush=True)


async def _main():
    log_startup()
    await serve(HOST, PORT, route, on_event=_evt)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        print("\nshutting down")
