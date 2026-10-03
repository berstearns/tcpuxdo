#!/usr/bin/env python3
"""join_server.py — a TEMPORARY "join with a code" endpoint that runs on the
relay box, started and stopped from main-laptop-1 by join/tcx-join.

WHAT:  GET /join?code=<code>&worker=<name>
         right code  → the CALLER's IP is added to the relay allowlist (through
                       the relay's own admin port, 127.0.0.1:<admin-port>, with
                       the admin token) → 200 "JOINED <ip>"
         wrong code  → 403; the 3rd wrong try from one IP bans that IP here
       GET /health   → 200 {"ok":true,"expires_in":…,"uses_left":…} (no secrets)
       The server EXITS by itself when the TTL ends or the last use is spent.

WHY:   2026-10-03, Bernardo: a worker on an unknown IP (another house, a
       rotated ISP address) cannot reach the relay, and the person at that
       machine is not technical. Same strategy as fserve: main launches a
       temporary, code-protected door on the relay; the worker uses the code
       once to let itself in. The admin token never leaves main + relay.

INPUTS: --env-file FILE  (mode 600, written by tcx-join, DELETED on read) with
          JOIN_CODE, ADMIN_TOKEN, ADMIN_PORT, JOIN_TTL_SECS, JOIN_USES,
          JOIN_WORKER (optional: only this worker name may join)
        --port N         listen port (default 9102), all interfaces
OUTPUTS: one log line per request on stdout (the tmux pane on the relay).
        exit 0 on TTL/uses exhausted, 2 on bad config.
STDLIB ONLY — no tcpuxdo import, so it cannot break the queue or the admin.
"""
import argparse, hmac, json, os, socket, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ap = argparse.ArgumentParser()
ap.add_argument("--env-file", required=True)
ap.add_argument("--port", type=int, default=9102)
a = ap.parse_args()

cfg = {}
try:
    with open(a.env_file) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.rstrip("\n").split("=", 1)
                cfg[k.strip()] = v.strip()
finally:
    try: os.unlink(a.env_file)          # secrets live only in this process now
    except OSError: pass

CODE = cfg.get("JOIN_CODE", "")
TOKEN = cfg.get("ADMIN_TOKEN", "")
ADMIN_PORT = int(cfg.get("ADMIN_PORT", "0") or 0)
TTL = int(cfg.get("JOIN_TTL_SECS", "1800"))
USES = int(cfg.get("JOIN_USES", "1"))
ONLY_WORKER = cfg.get("JOIN_WORKER", "")
if len(CODE) < 8 or not TOKEN or not ADMIN_PORT:
    print("bad config: need JOIN_CODE(>=8), ADMIN_TOKEN, ADMIN_PORT", flush=True); sys.exit(2)

DEADLINE = time.time() + TTL       # provisional; reset right after bind
state = {"uses_left": USES, "bad": {}, "banned": set()}
lock = threading.Lock()


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def admin_allow(ip):
    """Same framed-JSON protocol as tcpuxdo's admin port (allowlist_server.py)."""
    s = socket.create_connection(("127.0.0.1", ADMIN_PORT), timeout=10)
    try:
        body = json.dumps({"op": "allow", "ip": ip, "token": TOKEN}).encode()
        s.sendall(struct.pack("!I", len(body)) + body)
        hdr = b""
        while len(hdr) < 4:
            c = s.recv(4 - len(hdr))
            if not c: raise ConnectionError("admin closed")
            hdr += c
        n = struct.unpack("!I", hdr)[0]
        buf = b""
        while len(buf) < n:
            c = s.recv(n - len(buf))
            if not c: raise ConnectionError("admin closed")
            buf += c
        return json.loads(buf)
    finally:
        s.close()


def stop_soon(server, why):
    log(f"closing: {why}")
    threading.Thread(target=server.shutdown, daemon=True).start()


class H(BaseHTTPRequestHandler):
    def log_message(self, *args):          # silence default access log
        pass

    def reply(self, code, text):
        data = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        ip = self.client_address[0]
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/health":
            with lock:
                body = {"ok": True, "expires_in": int(DEADLINE - time.time()),
                        "uses_left": state["uses_left"]}
            return self.reply(200, json.dumps(body))
        if u.path != "/join":
            return self.reply(404, "not found")
        with lock:
            if ip in state["banned"]:
                log(f"{ip} banned — ignored")
                return self.reply(403, "BANNED")
            if state["uses_left"] <= 0 or time.time() > DEADLINE:
                return self.reply(410, "EXPIRED — ask Bernardo for a new code")
            code = (q.get("code") or [""])[0]
            worker = (q.get("worker") or [""])[0]
            if not hmac.compare_digest(code, CODE) or (ONLY_WORKER and worker != ONLY_WORKER):
                n = state["bad"].get(ip, 0) + 1
                state["bad"][ip] = n
                if n >= 3: state["banned"].add(ip)
                log(f"{ip} WRONG code/worker ({n}/3) worker={worker!r}")
                return self.reply(403, "WRONG CODE")
            state["uses_left"] -= 1
            left = state["uses_left"]
        try:
            r = admin_allow(ip)
        except Exception as e:
            log(f"{ip} admin call failed: {type(e).__name__}: {e}")
            with lock: state["uses_left"] += 1       # nothing happened: give the use back
            return self.reply(502, "SERVER ERROR — the relay admin did not answer")
        if r.get("ok"):
            log(f"{ip} JOINED as worker={worker!r} (uses left {left})")
            self.reply(200, f"JOINED {ip}")
        else:
            log(f"{ip} admin refused: {r.get('err_code')} {r.get('hint', '')}")
            self.reply(502, f"REFUSED {r.get('err_code')}")
        if left <= 0:
            stop_soon(self.server, "all uses spent")


class Server(ThreadingHTTPServer):
    # HTTPServer.server_bind() calls socket.getfqdn() — a reverse-DNS lookup
    # that took 5 s on main-laptop-1 (2026-10-03) and would eat a short TTL.
    # The name is only used for logging, so skip the lookup.
    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


srv = Server(("0.0.0.0", a.port), H)
DEADLINE = time.time() + TTL       # the TTL starts when the door is actually open
log(f"join door open on :{a.port} for {TTL}s, {USES} use(s)"
    + (f", only worker {ONLY_WORKER!r}" if ONLY_WORKER else ""))
def _ttl_watch():
    # A plain sleeping thread, not threading.Timer: in a local test on
    # 2026-10-03 a Timer never fired next to serve_forever(); this did.
    while time.time() < DEADLINE:
        time.sleep(min(5.0, max(0.1, DEADLINE - time.time())))
    stop_soon(srv, "ttl reached")


threading.Thread(target=_ttl_watch, daemon=True).start()   # daemon: never outlives the server
srv.serve_forever(poll_interval=0.5)
log("join door closed")
