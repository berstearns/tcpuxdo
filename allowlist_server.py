"""tcpux allowlist admin — TCP server + client in one file.

Concurrency model: asyncio
Communication:     framed-JSON over TCP via proto.serve/rpc
Cancellation:      KeyboardInterrupt at top-level asyncio.run
Shared state:      on-disk JSON db (one-writer-at-a-time via os.replace atomicity)

Two mutation ops (the redux entrypoints) and one read op:

    {"op":"allow","ip":"1.2.3.4","token":"..."}   → allow reducer
    {"op":"block","ip":"1.2.3.4","token":"..."}   → block reducer
    {"op":"get"}                                   → dump current state

Auth is a shared admin token (TCPUX_ADMIN_TOKEN). The token gates mutations
only; `get` is readable so the main server can smoke-test its db path.

CLI modes (same file, same deps):

    python allowlist_server.py serve
    python allowlist_server.py allow 1.2.3.4
    python allowlist_server.py block 1.2.3.4
    python allowlist_server.py get
"""
import argparse, asyncio, hmac, json, os, sys, time

import allowlist
from proto import serve, rpc


def _req_env(name):
    v = os.environ.get(name)
    if not v:
        raise SystemExit(f"required env var {name} not set — see deploy/.env")
    return v


HOST  = os.environ.get("TCPUX_HOST", "0.0.0.0")
PORT  = int(_req_env("TCPUX_ADMIN_PORT"))
# DB is only needed for `serve` mode. CLI client modes (allow/block/get)
# are pure TCP and never touch the file.
DB    = os.environ.get("TCPUX_ALLOWLIST_DB", "")
TOKEN = os.environ.get("TCPUX_ADMIN_TOKEN", "")


C = {"reset":"\033[0m","dim":"\033[2m","bold":"\033[1m",
     "red":"\033[91m","green":"\033[92m","yellow":"\033[93m",
     "cyan":"\033[96m","magenta":"\033[95m"}

def _ts(): return time.strftime("%H:%M:%S")

def log(level, op, msg, addr=""):
    col = {"INF":C["green"],"WRN":C["yellow"],"ERR":C["red"]}.get(level,C["reset"])
    src = f" {C['dim']}← {addr}{C['reset']}" if addr else ""
    print(f"{C['dim']}{_ts()}{C['reset']} {col}{level}{C['reset']} "
          f"{C['cyan']}{C['bold']}{op:>9}{C['reset']} {msg}{src}", flush=True)


def _reject(code, hint, op, addr):
    log("WRN", op, f"{C['red']}reject {code}{C['reset']} {C['dim']}{hint}{C['reset']}", addr)
    return {"ok": False, "err_code": code, "hint": hint}


def _auth(msg, op, addr):
    if not TOKEN:
        return _reject("ADMIN_DISABLED",
                       "TCPUX_ADMIN_TOKEN not set on server", op, addr)
    tok = msg.get("token", "")
    if not hmac.compare_digest(tok, TOKEN):
        return _reject("BAD_TOKEN", "admin token mismatch", op, addr)
    return None


# ── Route ───────────────────────────────────────────────────────

async def route(msg, addr):
    op = msg.get("op", "")

    if op in ("allow", "block"):
        err = _auth(msg, op, addr)
        if err: return err
        ip = msg.get("ip")
        try:
            state = allowlist.load(DB)
            new = allowlist.allow(state, ip) if op == "allow" else allowlist.block(state, ip)
            allowlist.save(DB, new)
        except ValueError as e:
            # Axiom failure from reducer.
            code, _, hint = str(e).partition(": ")
            return _reject(code or "REDUCER_FAIL", hint or str(e), op, addr)
        except AssertionError as e:
            return _reject("INVARIANT_BROKEN", str(e), op, addr)
        size_a = len(new["allowed"]); size_b = len(new["blocked"])
        log("INF", op,
            f"{C['bold']}{ip}{C['reset']} → "
            f"allowed={C['green']}{size_a}{C['reset']} "
            f"blocked={C['red']}{size_b}{C['reset']}", addr)
        return {"ok": True, "ip": ip, "state": new}

    if op == "get":
        try:
            state = allowlist.load(DB)
        except Exception as e:
            return _reject("DB_READ", str(e), op, addr)
        log("INF", op, f"served state ({len(state.get('allowed',[]))} allowed)", addr)
        return {"ok": True, "state": state}

    return _reject("UNKNOWN_OP", f"unknown op {op!r}", op or "???", addr)


def _evt(kind, **kv):
    tag = "CON" if kind == "connect" else "DIS"
    col = C["green"] if kind == "connect" else C["yellow"]
    print(f"{C['dim']}{_ts()}{C['reset']} {col}{tag}{C['reset']} "
          f"{C['dim']}← {kv.get('addr','?')}{C['reset']}", flush=True)


async def _main_serve():
    if not DB:
        raise SystemExit("TCPUX_ALLOWLIST_DB must be set for serve mode")
    print(f"""
{C['cyan']}{C['bold']}╔══════════════════════════════════════════╗
║   TCPUX ALLOWLIST ADMIN (redux reducer)  ║
╚══════════════════════════════════════════╝{C['reset']}
  {C['green']}●{C['reset']} Host:  {C['bold']}{HOST}{C['reset']}
  {C['green']}●{C['reset']} Port:  {C['bold']}{PORT}{C['reset']}
  {C['green']}●{C['reset']} DB:    {C['bold']}{DB}{C['reset']}
  {C['green']}●{C['reset']} Token: {C['bold']}{'set' if TOKEN else C['red']+'UNSET (mutations disabled)'+C['reset']+C['bold']}{C['reset']}
""", flush=True)
    await serve(HOST, PORT, route, on_event=_evt)


# ── CLI client modes ────────────────────────────────────────────

def _client(op, **extra):
    host = os.environ.get("TCPUX_ADMIN_HOST", "127.0.0.1")
    port = PORT
    msg = {"op": op, **extra}
    if op in ("allow", "block"):
        msg["token"] = TOKEN
    return rpc(host, port, msg)


def main():
    ap = argparse.ArgumentParser(description="tcpux allowlist admin")
    ap.add_argument("mode", choices=["serve", "allow", "block", "get"])
    ap.add_argument("ip", nargs="?")
    args = ap.parse_args()

    if args.mode == "serve":
        try:
            asyncio.run(_main_serve())
        except KeyboardInterrupt:
            print("\nshutting down")
        return

    if args.mode in ("allow", "block") and not args.ip:
        ap.error(f"{args.mode} requires an ip")

    r = _client(args.mode, **({"ip": args.ip} if args.ip else {}))
    print(json.dumps(r, indent=2))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
