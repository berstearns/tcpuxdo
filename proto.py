"""Framed-JSON TCP protocol. Zero deps.

Concurrency model: asyncio (server side) + blocking sockets (rpc client)
Communication:     framed JSON bytes over TCP
Cancellation:      per-connection task cancel; client uses socket timeout
Shared state:      none — each connection owns its reader/writer pair

Wire format: [4-byte big-endian length][JSON body]
"""
import asyncio, json, socket, struct


MAX_FRAME = 1 * 1024 * 1024


async def _write_frame(w, obj):
    data = json.dumps(obj).encode()
    w.write(struct.pack("!I", len(data)) + data)
    await w.drain()


async def _read_frame(r):
    hdr = await r.readexactly(4)
    size = struct.unpack("!I", hdr)[0]
    if size > MAX_FRAME:
        raise ValueError(f"frame too large: {size}")
    return json.loads(await r.readexactly(size))


async def serve(host, port, route, on_event=None):
    """Start a TCP server. `route(msg, addr)` → dict response."""
    async def handle(r, w):
        peer = w.get_extra_info("peername")
        addr = f"{peer[0]}:{peer[1]}" if peer else "?"
        if on_event: on_event("connect", addr=addr)
        try:
            while True:
                msg = await _read_frame(r)
                resp = await route(msg, addr)
                await _write_frame(w, resp)
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            try: await _write_frame(w, {"ok": False, "err_code": "INTERNAL", "hint": repr(e)})
            except Exception: pass
        finally:
            if on_event: on_event("disconnect", addr=addr)
            try: w.close()
            except Exception: pass

    srv = await asyncio.start_server(handle, host, port, reuse_address=True)
    async with srv:
        await srv.serve_forever()


# ── Sync client helpers ─────────────────────────────────────────

def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed")
        buf += c
    return buf


def rpc(host, port, msg, timeout=10):
    s = socket.socket()
    s.settimeout(timeout)
    s.connect((host, port))
    try:
        data = json.dumps(msg).encode()
        s.sendall(struct.pack("!I", len(data)) + data)
        n = struct.unpack("!I", _recv_exact(s, 4))[0]
        return json.loads(_recv_exact(s, n))
    finally:
        s.close()
