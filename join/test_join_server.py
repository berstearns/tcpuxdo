#!/usr/bin/env python3
"""test_join_server.py — local test of join/join_server.py, no relay needed.

A fake admin port (same framed-JSON protocol) records every "allow". Checks:
  /health is up · wrong code → 403 · 3rd wrong try bans the IP · right code →
  200 JOINED + exactly one allow with the caller's IP + the right token ·
  the env file is deleted at start · the server exits after its last use.
Run:  python3 join/test_join_server.py      (exit 0 = all pass)
"""
import json, os, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
calls = []


def fake_admin(sock):
    while True:
        c, _ = sock.accept()
        n = struct.unpack("!I", c.recv(4))[0]
        msg = json.loads(c.recv(n))
        calls.append(msg)
        out = json.dumps({"ok": True, "ip": msg.get("ip")}).encode()
        c.sendall(struct.pack("!I", len(out)) + out)
        c.close()


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status, r.read().decode().strip()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode().strip()


adm = socket.socket(); adm.bind(("127.0.0.1", 0)); adm.listen(5)
threading.Thread(target=fake_admin, args=(adm,), daemon=True).start()
port = free_port()
envf = tempfile.NamedTemporaryFile("w", delete=False, suffix=".env")
envf.write(f"JOIN_CODE=test-code-123\nADMIN_TOKEN=tok-xyz\nADMIN_PORT={adm.getsockname()[1]}\n"
           "JOIN_TTL_SECS=60\nJOIN_USES=1\nJOIN_WORKER=wsl-\n")
envf.close()
p = subprocess.Popen([sys.executable, os.path.join(HERE, "join_server.py"), "--env-file", envf.name, "--port", str(port)],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
base = f"http://127.0.0.1:{port}"
for _ in range(50):
    try: get(base + "/health"); break
    except Exception: time.sleep(0.1)

fails = []
def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

check("env file deleted at start", not os.path.exists(envf.name))
s, b = get(base + "/health"); check("health 200 + uses_left 1", s == 200 and json.loads(b)["uses_left"] == 1)
s, b = get(base + "/join?code=nope&worker=wsl-"); check("wrong code → 403", s == 403)
s, b = get(base + "/join?code=test-code-123&worker=other"); check("wrong worker → 403", s == 403)
check("no allow after wrong tries", calls == [])
s, b = get(base + "/join?code=test-code-123&worker=wsl-"); check("right code → 200 JOINED", s == 200 and b.startswith("JOINED 127.0.0.1"))
check("exactly one allow, caller ip, token", len(calls) == 1 and calls[0] == {"op": "allow", "ip": "127.0.0.1", "token": "tok-xyz"})
try:
    p.wait(timeout=5); check("server exits after last use", p.returncode == 0)
except subprocess.TimeoutExpired:
    p.kill(); check("server exits after last use", False)

# ban: a fresh server, 3 wrong tries, then the right code is refused
port2 = free_port()
envf2 = tempfile.NamedTemporaryFile("w", delete=False, suffix=".env")
envf2.write(f"JOIN_CODE=test-code-123\nADMIN_TOKEN=tok\nADMIN_PORT={adm.getsockname()[1]}\nJOIN_TTL_SECS=60\nJOIN_USES=1\n")
envf2.close()
p2 = subprocess.Popen([sys.executable, os.path.join(HERE, "join_server.py"), "--env-file", envf2.name, "--port", str(port2)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
b2 = f"http://127.0.0.1:{port2}"
for _ in range(50):
    try: get(b2 + "/health"); break
    except Exception: time.sleep(0.1)
for _ in range(3): get(b2 + "/join?code=bad")
s, b = get(b2 + "/join?code=test-code-123"); check("3 wrong tries → banned even with right code", s == 403 and "BANNED" in b)
p2.kill()

print("ALL PASS" if not fails else f"{len(fails)} FAIL")
sys.exit(1 if fails else 0)
