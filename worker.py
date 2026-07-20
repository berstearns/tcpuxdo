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
import argparse, json, os, shlex, socket, stat, subprocess, sys, time

import axioms
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


# ── git provenance ──────────────────────────────────────────────

def git_meta():
    """Git SHA/branch of the repo this worker is running FROM, captured once at
    startup — so it reflects the code actually loaded into this process (a
    pull-without-restart shows as 'behind' until the worker is restarted, which
    is exactly what the redeploy flow does). Reported with each panes-update so
    the fleet dashboard can flag commit drift."""
    root = os.path.dirname(os.path.abspath(__file__))
    def g(*a):
        try:
            return subprocess.run(("git", "-C", root) + a,
                                  capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            return ""
    return {
        "sha":    g("rev-parse", "--short=8", "HEAD"),
        "branch": g("rev-parse", "--abbrev-ref", "HEAD"),
        "dirty":  bool(g("status", "--porcelain")),
    }


# ── tmux wrappers ───────────────────────────────────────────────

def _tmux(*args, check=True):
    r = subprocess.run(("tmux",) + args, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {' '.join(args)}: {r.stderr.strip()}")
    return r


# A user can run SEVERAL tmux servers, one per socket in /tmp/tmux-<uid>/.
# `tmux list-panes -a` only ever covers ONE of them (the default, or whatever
# $TMUX points at), so panes on any other socket are invisible to the relay —
# e.g. Claude Code instances launched under `tmux -L claude8`. We enumerate
# every socket and remember which one owns each pane, so send-keys/capture can
# be routed back to the right server.
_SKIPPED = set()      # pane ids already warned about (log once each)
PANE_SOCKETS = {}     # pane_id → socket path (None = tmux's default resolution)
SESSION_SOCKETS = {}  # session → socket path


def _sockets_from_procs():
    """Socket paths mined from the command lines of running tmux processes.

    Needed because a socket may live ANYWHERE, not just /tmp/tmux-<uid>/ —
    e.g. `tmux -S /home/claude/.tmux-claude4.sock`. `-L NAME` is the same thing
    spelled relative to the default dir.
    """
    d = f"/tmp/tmux-{os.getuid()}"
    found = set()
    try:
        r = subprocess.run(("ps", "-eo", "args="),
                           capture_output=True, text=True, timeout=5)
    except Exception:
        return found
    for line in r.stdout.splitlines():
        try:
            toks = shlex.split(line)
        except ValueError:
            toks = line.split()
        if not toks or not os.path.basename(toks[0]).startswith("tmux"):
            continue
        for i, t in enumerate(toks[:-1]):
            if t == "-S":
                found.add(toks[i + 1])
            elif t == "-L":
                found.add(os.path.join(d, toks[i + 1]))
    return found


def list_sockets():
    """Socket paths for every tmux server this user can reach, default-first.

    Union of /tmp/tmux-<uid>/* and sockets mined from running tmux processes.
    Override with TCPUX_TMUX_SOCKETS (comma-separated paths or bare names).
    Returns [None] when nothing is found, which makes the caller fall back to
    tmux's own default resolution — i.e. the old behaviour.
    """
    d = f"/tmp/tmux-{os.getuid()}"
    env = os.environ.get("TCPUX_TMUX_SOCKETS", "").strip()
    if env:
        return [p if "/" in p else os.path.join(d, p)
                for p in (x.strip() for x in env.split(",")) if p]

    cand = set()
    try:
        cand.update(os.path.join(d, n) for n in os.listdir(d))
    except OSError:
        pass
    cand.update(_sockets_from_procs())

    socks, seen = [], set()
    for p in cand:
        try:
            real = os.path.realpath(p)
            if real in seen or not stat.S_ISSOCK(os.stat(real).st_mode):
                continue
            os.stat(p)              # reachable?
        except OSError:
            continue                # gone, or not ours — skip quietly
        seen.add(real)
        socks.append(p)
    # "default" first so it wins any session-name collision across sockets.
    socks.sort(key=lambda p: (os.path.basename(p) != "default", p))
    return socks or [None]


def _sock_args(sock):
    return ("-S", sock) if sock else ()


def _tmux_pane(pane_id, *args, **kw):
    """Run a tmux command against the server that owns `pane_id`."""
    return _tmux(*_sock_args(PANE_SOCKETS.get(pane_id)), *args, **kw)


def _tmux_session(session, *args, **kw):
    """Run a tmux command against the server that owns `session`."""
    return _tmux(*_sock_args(SESSION_SOCKETS.get(session)), *args, **kw)


def list_panes():
    """Return dict[pane_id → {busy, cmd, pid}] across ALL of this user's tmux
    servers.

    `pane_id` = `session_name:window_index:pane_index` — the canonical tcpux
    form. It carries no socket component (the PANE_ID grammar is a strict
    triple), so if two sockets host the same session name the first socket
    wins and the duplicate is skipped.
    """
    fmt = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_pid}"
    panes, owners, sess = {}, {}, {}
    for sock in list_sockets():
        try:
            r = _tmux(*_sock_args(sock), "list-panes", "-a", "-F", fmt, check=False)
        except FileNotFoundError:
            print("  tmux not installed", flush=True)
            return {}
        if r.returncode != 0:
            continue
        for line in r.stdout.strip().splitlines():
            parts = line.split("\t")
            if len(parts) != 5:
                continue
            s, w, p, cmd, pid = parts
            pane_id = f"{s}:{w}:{p}"
            # A session name outside IDENT ([A-Za-z0-9_-]+) — a dot, a space —
            # would fail axiom U2, and check_update rejects the WHOLE update on
            # the first bad id. Dropping the offender here keeps one oddly-named
            # session from blacking out every pane this node reports.
            if not axioms.PANE_ID_RE.match(pane_id):
                if pane_id not in _SKIPPED:
                    _SKIPPED.add(pane_id)
                    print(f"  skipping unrepresentable pane id {pane_id!r} "
                          f"(session must match [A-Za-z0-9_-]+)", flush=True)
                continue
            if pane_id in panes:      # collision across sockets — first wins
                continue
            panes[pane_id] = {"busy": cmd not in IDLE_CMDS, "cmd": cmd, "pid": pid}
            owners[pane_id] = sock
            sess.setdefault(s, sock)
    PANE_SOCKETS.clear();    PANE_SOCKETS.update(owners)
    SESSION_SOCKETS.clear(); SESSION_SOCKETS.update(sess)
    return panes


# tmux caps the total length of a single command string (~16 KB); anything
# larger comes back as "command too long" and NOTHING is typed. So a big payload
# (e.g. a whole markdown file) must be sent as several `-l` keystrokes.
SEND_CHUNK_BYTES = 8000


def _chunks(text, limit=SEND_CHUNK_BYTES):
    """Split `text` into pieces whose UTF-8 encoding is <= limit bytes, never
    splitting a multi-byte character (a split mid-codepoint would corrupt it)."""
    out, buf, size = [], [], 0
    for ch in text:
        n = len(ch.encode())
        if size + n > limit and buf:
            out.append("".join(buf)); buf, size = [], 0
        buf.append(ch); size += n
    if buf:
        out.append("".join(buf))
    return out or [text]


def tmux_send_keys(pane_id, cmd):
    s, w, p = pane_id.split(":", 2)
    target = f"{s}:{w}.{p}"
    # Send the prompt text and the submitting Enter as TWO keystrokes, not one.
    # Claude Code (and other Ink / bracketed-paste TUIs) treat a newline that
    # arrives fused with pasted text as a literal newline in the input box — so a
    # single `send-keys <text> Enter` types the prompt but never submits it.
    # `-l` sends the text literally; a short settle lets the TUI leave paste-mode;
    # then a standalone Enter registers as a real Return. Shells are unaffected.
    #
    # The text may span several `-l` calls (see SEND_CHUNK_BYTES) — they land in
    # the input box back-to-back, so the pane still sees ONE prompt, submitted by
    # the single trailing Enter.
    parts = _chunks(cmd)
    for part in parts:
        _tmux_pane(pane_id, "send-keys", "-t", target, "-l", part)
        if len(parts) > 1:
            time.sleep(0.05)      # let the TUI drain its input buffer
    time.sleep(0.3)
    _tmux_pane(pane_id, "send-keys", "-t", target, "Enter")


def tmux_capture_pane(pane_id, lines=None):
    """Return the pane's visible text (or last `lines` of scrollback) via
    `tmux capture-pane -p`. `-S -N` extends the start N lines up the history."""
    s, w, p = pane_id.split(":", 2)
    target = f"{s}:{w}.{p}"
    args = ["capture-pane", "-p", "-t", target]
    if lines:
        args += ["-S", f"-{int(lines)}"]
    return _tmux_pane(pane_id, *args).stdout


def tmux_new_session(session):
    _tmux("new-session", "-d", "-s", session)


def tmux_new_window(session, window=None):
    if window is None:
        _tmux_session(session, "new-window", "-t", session)
    else:
        _tmux_session(session, "new-window", "-t", f"{session}:", "-n", window)


def tmux_split_window(session, window):
    _tmux_session(session, "split-window", "-t", f"{session}:{window}")


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


def run_capture_pane(pane_id, lines=None):
    # No busy gate: reading a busy pane's output is the whole point.
    if pane_id not in list_panes():
        return {"ok": False, "err": "pane vanished"}
    try:
        text = tmux_capture_pane(pane_id, lines)
    except Exception as e:
        return {"ok": False, "err": str(e)}
    return {"ok": True, "pane": pane_id, "text": text}


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
    "capture-pane":   lambda c: run_capture_pane(c["pane"], c.get("lines")),
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

    meta = git_meta()
    print(f"tcpux-worker '{args.name}' → {args.host}:{args.port} "
          f"(poll={args.poll}s sync={args.sync}s) "
          f"[{meta['branch']}@{meta['sha']}{'*' if meta['dirty'] else ''}]", flush=True)

    last_sync = 0.0
    while True:
        try:
            now = time.time()
            if now - last_sync >= args.sync:
                panes = list_panes()
                resp = rpc(args.host, args.port,
                           {"op": "tmux-panes-update", "worker": args.name, "panes": panes, "meta": meta})
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
