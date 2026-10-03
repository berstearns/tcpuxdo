#!/usr/bin/env python3
"""Maintain an isolated WSL probe worker and prove relay -> tmux -> relay.

Run by wsl-rescue.sh after the main worker is connected. The probe has its own
worker name and FIFO queue, so old jobs for the real worker cannot block it.
Only its disposable tcpuxdo-probe shell receives the marker command.
"""

import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
os.environ["TCPUX_CONNECT_RETRY_SECS"] = "3"
from proto import rpc  # noqa: E402

MAIN = os.environ.get("TCPUX_WORKER", "wsl-")
PROBE = os.environ.get("TCPUX_PROBE_WORKER", MAIN + "probe")
SHELL_SESSION = "tcpuxdo-probe"
WORKER_SESSION = "tcpuxdo-probe-worker"
HOST = os.environ.get("TCPUX_HOST", "")
PORT = int(os.environ.get("TCPUX_PORT", "0"))


def fail(reason):
    print(f"PROBE_FAIL {reason}", flush=True)
    raise SystemExit(1)


def tmux(*args):
    return subprocess.run(("tmux",) + args, capture_output=True, text=True)


def pane(session):
    r = tmux("list-panes", "-t", session,
             "-F", "#{session_name}:#{window_index}:#{pane_index}\t#{pane_current_command}")
    if r.returncode != 0 or not r.stdout.strip():
        fail(f"tmux session {session} has no pane: {r.stderr.strip()}")
    first = r.stdout.splitlines()[0].split("\t", 1)
    return first[0], first[1] if len(first) > 1 else ""


def ensure_shell():
    if tmux("has-session", "-t", SHELL_SESSION).returncode != 0:
        r = tmux("new-session", "-d", "-s", SHELL_SESSION, "-n", "probe", "-c", str(ROOT))
        if r.returncode != 0:
            fail(f"could not create dummy tmux shell: {r.stderr.strip()}")
    pane_id, command = pane(SHELL_SESSION)
    if command not in {"bash", "zsh", "fish", "sh", "dash"}:
        r = tmux("respawn-pane", "-k", "-t", pane_id, "bash -l")
        if r.returncode != 0:
            fail(f"could not reset dummy tmux shell: {r.stderr.strip()}")
    tmux("select-pane", "-t", pane_id, "-T", "tcpuxdo-probe-shell")
    return pane_id


def worker_command():
    return (f"cd {shlex.quote(str(ROOT))} && set -a && . ./.env && set +a "
            f"&& exec python3 worker.py --name {shlex.quote(PROBE)} "
            '--host "$TCPUX_HOST" --port "$TCPUX_PORT"')


def restart_worker():
    command = worker_command()
    if tmux("has-session", "-t", WORKER_SESSION).returncode != 0:
        r = tmux("new-session", "-d", "-s", WORKER_SESSION, "-n", "worker",
                 "-c", str(ROOT), command)
    else:
        worker_pane, _ = pane(WORKER_SESSION)
        r = tmux("respawn-pane", "-k", "-t", worker_pane, command)
    if r.returncode != 0:
        fail(f"could not start probe worker: {r.stderr.strip()}")
    print(f"probe worker {PROBE} started from current checkout", flush=True)


def state():
    try:
        result = rpc(HOST, PORT, {"op": "state"})
    except Exception as exc:
        fail(f"relay state unavailable: {type(exc).__name__}: {exc}")
    if not result.get("ok"):
        fail(f"relay rejected probe: {result.get('err_code', 'UNKNOWN')}")
    return result


def fresh(record):
    age = time.time() - record.get("last_update", 0)
    return 0 <= age <= 30


def wait_for_probe(pane_id, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        result = state()
        record = result.get("state", {}).get(PROBE, {})
        if fresh(record) and pane_id in record.get("panes", {}):
            return result
        if time.monotonic() >= deadline:
            fail(f"{PROBE} did not report fresh tmux pane {pane_id} within {seconds}s")
        time.sleep(2)


def wait_result(job_id, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            reply = rpc(HOST, PORT, {"op": "status", "id": job_id})
        except Exception as exc:
            fail(f"status #{job_id} unavailable: {type(exc).__name__}: {exc}")
        if not reply.get("ok"):
            fail(f"status #{job_id} rejected: {reply.get('err_code', 'UNKNOWN')}")
        if reply.get("result") is not None:
            return reply["result"]
        time.sleep(0.4)
    fail(f"job #{job_id} not acknowledged within {seconds}s")


def submit(op, pane_id, **fields):
    try:
        reply = rpc(HOST, PORT, {"op": op, "worker": PROBE, "pane": pane_id, **fields})
    except Exception as exc:
        fail(f"{op} submit unavailable: {type(exc).__name__}: {exc}")
    if not reply.get("ok"):
        fail(f"{op} rejected: {reply.get('err_code', 'UNKNOWN')} {reply.get('hint', '')}")
    result = wait_result(reply["id"])
    if not result.get("ok"):
        fail(f"{op} failed in tmux: {result.get('err', 'UNKNOWN')}")
    return result


def main():
    if not HOST or not PORT:
        fail("TCPUX_HOST/TCPUX_PORT missing from .env")
    pane_id = ensure_shell()
    restarted = False
    if os.environ.get("RESCUE_FORCE_RESTART"):
        restart_worker()
        restarted = True
    elif tmux("has-session", "-t", WORKER_SESSION).returncode != 0:
        restart_worker()
        restarted = True
    elif pane(WORKER_SESSION)[1] != "python3":
        restart_worker()
        restarted = True

    result = wait_for_probe(pane_id) if restarted else state()
    record = result.get("state", {}).get(PROBE, {})
    if not fresh(record) or pane_id not in record.get("panes", {}):
        restart_worker()
        result = wait_for_probe(pane_id)

    pending = len(result.get("queue", {}).get(PROBE, []))
    if pending:
        fail(f"{PROBE} has {pending} pending job(s); not adding another")

    marker = f"TCPUX_WSL_PROBE_{int(time.time())}_{os.getpid()}"
    submit("send-keys", pane_id, cmd=f"echo {marker}")
    time.sleep(0.4)
    capture = submit("capture-pane", pane_id)
    if marker not in (line.strip() for line in capture.get("text", "").splitlines()):
        fail(f"marker absent from output of dummy pane {pane_id}")

    main_record = result.get("state", {}).get(MAIN, {})
    main_age = int(time.time() - main_record.get("last_update", 0))
    main_queue = len(result.get("queue", {}).get(MAIN, []))
    print(f"PROBE_OK worker={PROBE} pane={pane_id} "
          f"main_heartbeat_age={main_age}s main_queue={main_queue}", flush=True)


if __name__ == "__main__":
    main()
