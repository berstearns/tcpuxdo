"""tcpux axioms — strict, pure predicates for every accepted command.

Every axiom is a small boolean predicate returning (ok, err_code, hint).
Axioms are grouped per command family and labeled with a stable code so
that a rejected sender can programmatically decide the next move
(typically: cascade to a creation command).

Identifier alphabet and pane-id grammar are the algebraic foundation:

    IDENT    := [A-Za-z0-9_-]+
    PANE_ID  := IDENT ":" IDENT ":" IDENT           (session:window:pane)
    WIN_ID   := IDENT ":" IDENT                     (session:window)

Server state has the shape:

    STATE = {
        worker_id: {
            "last_update": float,
            "panes": {pane_id: {"busy": bool, "cmd": str, "ts": float}}
        }
    }

Nothing here touches the network or tmux. Everything is a pure check
over plain Python data so the rules stay inspectable and testable.
"""
import re

IDENT_RE   = re.compile(r"^[A-Za-z0-9_-]+$")
PANE_ID_RE = re.compile(r"^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$")
WIN_ID_RE  = re.compile(r"^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$")

OK = (True, None, None)


def _fail(code, hint):
    return (False, code, hint)


def split_pane_id(pane_id):
    return tuple(pane_id.split(":", 2))


def window_prefix(pane_id):
    s, w, _ = split_pane_id(pane_id)
    return f"{s}:{w}"


def session_prefix(pane_id):
    return pane_id.split(":", 1)[0]


# ── U: tmux-panes-update (worker → server) ───────────────────────

def check_update(worker_id, panes):
    if not isinstance(worker_id, str) or not IDENT_RE.match(worker_id):
        return _fail("U1_BAD_WORKER_ID", "worker_id must match [A-Za-z0-9_-]+")
    if not isinstance(panes, dict):
        return _fail("U2_PANES_NOT_DICT", "panes must be a dict of pane_id → state")
    for pid, pst in panes.items():
        if not isinstance(pid, str) or not PANE_ID_RE.match(pid):
            return _fail("U2_BAD_PANE_ID", f"pane id {pid!r} must match session:window:pane")
        if not isinstance(pst, dict) or not isinstance(pst.get("busy", False), bool):
            return _fail("U3_BAD_PANE_STATE", f"pane {pid} must have busy:bool")
    return OK


# ── SK: send-keys (client → server, queued for worker) ──────────

def check_send_keys(state, worker_id, pane_id, cmd):
    if not isinstance(worker_id, str) or not IDENT_RE.match(worker_id):
        return _fail("SK1_BAD_WORKER_ID", "worker_id must match [A-Za-z0-9_-]+")
    if worker_id not in state:
        return _fail("SK1_WORKER_UNKNOWN",
                     "worker has not sent tmux-panes-update yet")
    if not isinstance(pane_id, str) or not PANE_ID_RE.match(pane_id):
        return _fail("SK2_BAD_PANE_ID", "pane must match session:window:pane")
    panes = state[worker_id].get("panes", {})
    if pane_id not in panes:
        return _fail("SK3_PANE_NOT_EXIST",
                     f"pane {pane_id} not in worker's current pane set — "
                     f"cascade to create-pane")
    if not isinstance(cmd, str) or not cmd:
        return _fail("SK4_BAD_CMD", "cmd must be a non-empty string")
    return OK


# ── CS: create-session ──────────────────────────────────────────

def check_create_session(state, worker_id, session):
    if worker_id not in state:
        return _fail("CS0_WORKER_UNKNOWN", "worker not registered")
    if not isinstance(session, str) or not IDENT_RE.match(session):
        return _fail("CS1_BAD_SESSION", "session must match [A-Za-z0-9_-]+")
    existing = {session_prefix(pid) for pid in state[worker_id].get("panes", {})}
    if session in existing:
        return _fail("CS2_SESSION_EXISTS", f"session {session} already exists")
    return OK


# ── CW: create-window ───────────────────────────────────────────

def check_create_window(state, worker_id, session, window):
    if worker_id not in state:
        return _fail("CW0_WORKER_UNKNOWN", "worker not registered")
    if not IDENT_RE.match(session or "") or not IDENT_RE.match(window or ""):
        return _fail("CW1_BAD_IDENT", "session and window must match [A-Za-z0-9_-]+")
    existing_sessions = {session_prefix(pid) for pid in state[worker_id].get("panes", {})}
    if session not in existing_sessions:
        return _fail("CW1_SESSION_MISSING",
                     f"session {session} does not exist — cascade to create-session")
    existing_windows = {window_prefix(pid) for pid in state[worker_id].get("panes", {})}
    if f"{session}:{window}" in existing_windows:
        return _fail("CW2_WINDOW_EXISTS", f"window {session}:{window} already exists")
    return OK


# ── CP: create-pane ─────────────────────────────────────────────

def check_create_pane(state, worker_id, pane_id):
    if worker_id not in state:
        return _fail("CP0_WORKER_UNKNOWN", "worker not registered")
    if not isinstance(pane_id, str) or not PANE_ID_RE.match(pane_id):
        return _fail("CP1_BAD_PANE_ID", "pane must match session:window:pane")
    panes = state[worker_id].get("panes", {})
    existing_windows = {window_prefix(pid) for pid in panes}
    existing_sessions = {session_prefix(pid) for pid in panes}
    s, w, _ = split_pane_id(pane_id)
    if s not in existing_sessions:
        return _fail("CP2_SESSION_MISSING",
                     f"session {s} missing — cascade to create-session")
    if f"{s}:{w}" not in existing_windows:
        return _fail("CP2_WINDOW_MISSING",
                     f"window {s}:{w} missing — cascade to create-window")
    if pane_id in panes:
        return _fail("CP3_PANE_EXISTS", f"pane {pane_id} already exists")
    return OK


# ── P: poll ─────────────────────────────────────────────────────

def check_poll(worker_id):
    if not isinstance(worker_id, str) or not IDENT_RE.match(worker_id):
        return _fail("P1_BAD_WORKER_ID", "worker_id must match [A-Za-z0-9_-]+")
    return OK


# ── A: ack ──────────────────────────────────────────────────────

def check_ack(queue_index, cmd_id):
    if not isinstance(cmd_id, int) or cmd_id not in queue_index:
        return _fail("A1_UNKNOWN_CMD", f"cmd_id {cmd_id} not dispatched")
    return OK


# ── SH: shortcut-set / shortcut-del ─────────────────────────────
# Shortcuts map a short opaque name to a (worker, pane) tuple. The
# namespace is global. Mutations are validated against the live STATE
# at write time; they are NOT revalidated on read — a stale shortcut
# falls through to SK3 at send-keys time, which is the canonical safety
# net.

SHORTCUT_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


def check_shortcut_set(state, shortcuts, name, worker_id, pane_id, force):
    if not isinstance(name, str) or not SHORTCUT_NAME_RE.match(name):
        return _fail("SH1_BAD_NAME", "name must match [A-Za-z0-9_-]{1,32}")
    if not isinstance(worker_id, str) or not IDENT_RE.match(worker_id):
        return _fail("SH2_BAD_WORKER_ID", "worker_id must match [A-Za-z0-9_-]+")
    if worker_id not in state:
        return _fail("SH2_WORKER_UNKNOWN",
                     "worker has not sent tmux-panes-update yet")
    if not isinstance(pane_id, str) or not PANE_ID_RE.match(pane_id):
        return _fail("SH3_BAD_PANE_ID", "pane must match session:window:pane")
    panes = state[worker_id].get("panes", {})
    if pane_id not in panes:
        return _fail("SH3_PANE_NOT_EXIST",
                     f"pane {pane_id} not in worker's current pane set")
    if not force and name in shortcuts:
        return _fail("SH4_NAME_TAKEN",
                     f"shortcut {name!r} already exists — pass force to overwrite")
    return OK


def check_shortcut_del(shortcuts, name):
    if not isinstance(name, str) or not SHORTCUT_NAME_RE.match(name):
        return _fail("SHD1_BAD_NAME", "name must match [A-Za-z0-9_-]{1,32}")
    if name not in shortcuts:
        return _fail("SHD1_UNKNOWN", f"shortcut {name!r} not found")
    return OK


# ── SK0: send-keys target resolution (shortcut OR pane, not both) ───────

def resolve_send_keys_target(shortcuts, msg):
    """Return (worker, pane, err) — exactly one of {shortcut, pane} must be set.

    Used by server.py before applying SK1-5. Keeps SK1-5 unchanged: they
    operate on (worker, pane) regardless of how the target was specified.
    """
    has_pane     = bool(msg.get("pane"))
    has_shortcut = bool(msg.get("shortcut"))
    if has_pane and has_shortcut:
        return (None, None, _fail("SK0_AMBIGUOUS",
                "specify exactly one of pane or shortcut, not both"))
    if not has_pane and not has_shortcut:
        return (None, None, _fail("SK0_NO_TARGET",
                "send-keys requires pane or shortcut"))
    if has_shortcut:
        name = msg["shortcut"]
        s = shortcuts.get(name)
        if not s:
            return (None, None, _fail("SK0_SHORTCUT_UNKNOWN",
                    f"shortcut {name!r} not registered"))
        return (s["worker"], s["pane"], OK)
    return (msg.get("worker"), msg["pane"], OK)
