"""tcpux allowlist — redux-style reducer + axioms + atomic file store.

State shape (persisted as JSON):

    {
      "allowed": ["1.2.3.4", ...],   # sorted, unique
      "blocked": ["5.6.7.8", ...],   # sorted, unique
      "updated_at": "2026-04-24T12:34:56Z"
    }

Actions (single entrypoint each — this is the reducer surface):

    {"type": "ALLOW", "ip": "<ipv4>"}   — ensure ip ∈ allowed, ip ∉ blocked
    {"type": "BLOCK", "ip": "<ipv4>"}   — ensure ip ∈ blocked, ip ∉ allowed

Everything else goes through these two actions, so the state transition
algebra stays closed and auditable.

Axioms (N = network layer)

    N1   ip must be a syntactically valid IPv4 dotted-quad
    N2   action.type ∈ {"ALLOW", "BLOCK"}

Invariants (checked after every reduce — a failing invariant raises,
never returns stale state):

    I1   allowed ∩ blocked = ∅
    I2   every element of allowed ∪ blocked satisfies N1
"""
import ipaddress, json, os, re, time

IPv4_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ── Axioms ──────────────────────────────────────────────────────

def check_ip(ip):
    if not isinstance(ip, str) or not IPv4_RE.match(ip):
        return (False, "N1_BAD_IP", f"not a valid IPv4 dotted-quad: {ip!r}")
    try:
        ipaddress.IPv4Address(ip)
    except Exception as e:
        return (False, "N1_BAD_IP", f"IPv4 parse: {e}")
    return (True, None, None)


def check_action(action):
    if not isinstance(action, dict):
        return (False, "N2_BAD_ACTION", "action must be a dict")
    kind = action.get("type")
    if kind not in ("ALLOW", "BLOCK"):
        return (False, "N2_BAD_ACTION", f"action.type must be ALLOW or BLOCK (got {kind!r})")
    return check_ip(action.get("ip"))


# ── Pure reducer ────────────────────────────────────────────────

def reduce(state, action):
    """Redux-style pure reducer. Returns new state; raises on bad input."""
    ok, code, hint = check_action(action)
    if not ok:
        raise ValueError(f"{code}: {hint}")
    allowed = set(state.get("allowed", []))
    blocked = set(state.get("blocked", []))
    ip = action["ip"]
    if action["type"] == "ALLOW":
        blocked.discard(ip)
        allowed.add(ip)
    else:  # BLOCK
        allowed.discard(ip)
        blocked.add(ip)
    new_state = {
        "allowed": sorted(allowed),
        "blocked": sorted(blocked),
        "updated_at": _now(),
    }
    _assert_invariants(new_state)
    return new_state


def _assert_invariants(state):
    a = set(state.get("allowed", []))
    b = set(state.get("blocked", []))
    overlap = a & b
    if overlap:
        raise AssertionError(f"I1_OVERLAP: {sorted(overlap)} appear in both allowed and blocked")
    for ip in a | b:
        ok, code, hint = check_ip(ip)
        if not ok:
            raise AssertionError(f"I2_BAD_IP: {code} {hint}")


# ── Single entrypoints (these wrap the reducer) ─────────────────

def allow(state, ip):
    return reduce(state, {"type": "ALLOW", "ip": ip})


def block(state, ip):
    return reduce(state, {"type": "BLOCK", "ip": ip})


# ── Read-side predicate used by server.py ──────────────────────

def is_allowed(state, ip):
    return ip in set(state.get("allowed", []))


def is_blocked(state, ip):
    return ip in set(state.get("blocked", []))


# ── File I/O ────────────────────────────────────────────────────

def load(path):
    if not os.path.isfile(path):
        return {"allowed": [], "blocked": [], "updated_at": _now()}
    with open(path) as f:
        state = json.load(f)
    _assert_invariants(state)
    return state


def save(path, state):
    _assert_invariants(state)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
