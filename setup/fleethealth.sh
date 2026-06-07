#!/usr/bin/env bash
# fleethealth.sh — tcpuxdo fleet health DASHBOARD (runs on MAIN).
#
#   fleethealth.sh              one colourful, width-aware frame
#   fleethealth.sh --watch [N]  repaint every N seconds (default 5)
#
# Reads the relay registry (`state` RPC) and renders per-node idle/busy/queued +
# claude-sendable counts, AND each node's git branch@sha (reported by its worker)
# vs. origin — with a one-line "is the fleet converged on latest?" verdict.
#
# Offline test: set TCPUX_STATE_JSON=<file> to render from a saved `state` blob
# (same shape as the `state` RPC reply) instead of hitting the relay.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; cd "$ROOT"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
[ -f .env ] && { set -a; . ./.env; set +a; }

# Reference "latest" = main's last-fetched view of origin/<branch> (cheap, no fetch;
# the redeploy timer keeps it fresh). Falls back to local HEAD if origin is unknown.
REF_BRANCH="${REDEPLOY_BRANCH:-master}"
REF_SHA="$(git -C "$ROOT" rev-parse --short=8 "origin/$REF_BRANCH" 2>/dev/null \
        || git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo '')"

# Firewall drift gate — the tcpuxdo relay shares the droplet firewall with credpipe,
# so a wiped pipe port (9100/9101) is the silent cause of "queue unreachable". Reuse
# do-firewall-sync --check (source of truth = .env). CACHED to FW_INTERVAL (default 60s)
# so the 5s repaint loop doesn't hammer doctl. Disable with FLEET_FW=0.
DO_AUTO="${DO_AUTO:-$HOME/p/all-my-tiny-projects/do-automation}"
FW_ID="${TCPUX_DO_FW_ID:-${CREDPIPE_DO_FW_ID:-}}"
[ -z "$FW_ID" ] && [ -f "$HOME/p/credpipe-main/.env" ] && FW_ID="$(sed -n 's/^CREDPIPE_DO_FW_ID=//p' "$HOME/p/credpipe-main/.env")"
fw_status(){
  { [ "${FLEET_FW:-1}" = 1 ] && [ -n "$FW_ID" ] && [ -x "$DO_AUTO/do-firewall-sync" ]; } || { echo ""; return; }
  local cache="/tmp/.fleethealth-fw.${FW_ID}" maxage="${FW_INTERVAL:-60}"
  if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -lt "$maxage" ]; then
    cat "$cache"; return
  fi
  local out; out="$(timeout 8 "$DO_AUTO/do-firewall-sync" "$FW_ID" --check 2>/dev/null)"
  if [ $? -eq 0 ]; then echo ok > "$cache"
  else echo "drift:$(printf '%s' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g" | sed -n 's/.*MISSING from firewall:[[:space:]]*//p')" > "$cache"; fi
  cat "$cache"
}

frame(){
  PYTHONPATH="$ROOT" COLS="$1" REF_SHA="$REF_SHA" REF_BRANCH="$REF_BRANCH" FW_STATUS="$(fw_status)" python3 - <<'PY'
import os, re, json, time, socket
socket.setdefaulttimeout(6)   # bound the state RPC — a dropped port must fail fast, never hang
W = max(46, min(int(os.environ.get("COLS","78") or 78), 100))
host = os.environ.get("TCPUX_HOST","?"); port = int(os.environ.get("TCPUX_PORT","0") or 0)
REF_SHA = os.environ.get("REF_SHA",""); REF_BRANCH = os.environ.get("REF_BRANCH","master")
FW = os.environ.get("FW_STATUS","")   # "" disabled | "ok" | "drift:<ports>"
B="\033[1m"; D="\033[2m"; X="\033[0m"; G="\033[32m"; R="\033[31m"; Y="\033[33m"; C="\033[36m"
vis = lambda s: len(re.sub(r"\033\[[0-9;]*m","",s))
dash = lambda n: "─"*max(n,0)
def row(s):
    p = W-3-vis(s); return "│ " + s + " "*(p if p>0 else 0) + "│"
sep = lambda: "├"+dash(W-2)+"┤"
def fit(s,m):
    m=max(m,1); return s if len(s)<=m else s[:m-1]+"…"
L=[]; title="tcpuxdo fleet"
ts = time.strftime("%a %H:%M")
_left="╭─ "+B+C+title+X+" "; _right=" "+D+ts+X+" ─╮"
L.append(_left+dash(W-vis(_left)-vis(_right))+_right)

sj = os.environ.get("TCPUX_STATE_JSON")
try:
    if sj:
        r = json.load(open(sj))
    else:
        from proto import rpc
        r = rpc(host, port, {"op":"state"})
except Exception as e:
    L.append(row(R+"● RELAY"+X+"   "+fit(f"{host}:{port}", W-14)))
    L.append(row("   "+R+"unreachable"+X+D+"  "+fit(str(e), W-18)+X))
    L.append(row(D+ts+X)); L.append("╰"+dash(W-2)+"╯"); print("\n".join(L)); raise SystemExit

state = r.get("state",{}); queue = r.get("queue",{})
nodes = sorted(state); nn = len(nodes)
tot_panes = sum(len(state[n].get("panes",{})) for n in nodes)
tot_q     = sum(len(queue.get(n,[]))         for n in nodes)
tot_busy  = sum(1 for n in nodes for p in state[n].get("panes",{}).values() if p.get("busy"))

# ── git convergence across the fleet ──
metas   = {n: (state[n].get("meta") or {}) for n in nodes}
have    = [n for n in nodes if metas[n].get("sha")]
shas    = {metas[n]["sha"] for n in have}
on_ref  = [n for n in have if metas[n].get("sha")==REF_SHA and metas[n].get("branch",REF_BRANCH)==REF_BRANCH]
if not have:
    verdict = Y+"⚠ git not reported"+X+D+" · redeploy relay"+X
elif len(have)==nn and len(shas)==1 and len(on_ref)==nn:
    verdict = G+"✓ converged"+X+D+"  "+X+B+REF_BRANCH+"@"+REF_SHA+X
elif len(shas)==1 and len(on_ref)==0:
    only=next(iter(shas)); verdict = Y+"⚠ all on "+only+X+D+" · behind latest "+X+B+REF_BRANCH+"@"+REF_SHA+X
else:
    verdict = R+f"⚠ drift {len(on_ref)}/{nn} on latest"+X+D+" "+X+B+REF_BRANCH+"@"+REF_SHA+X

ov = (G+"● HEALTHY"+X) if nn else (Y+"● NO NODES"+X)
L.append(row(ov+D+" · "+X+verdict))
L.append(sep())
fwtag = (D+" · "+X+G+"ⓕ✓"+X) if FW=="ok" else (D+" · "+X+R+"ⓕ✗"+X) if FW.startswith("drift:") else ""
L.append(row(G+"●"+X+" "+B+"RELAY"+X+"   "+fit(f"{host}:{port}", W-20)+G+"  reachable"+X+fwtag))
if FW.startswith("drift:"):
    L.append(row(R+"  ⓕ FIREWALL DRIFT"+X+D+" missing "+(FW[6:].strip() or "?")+" → do-firewall-sync"+X))
L.append(row(C+"●"+X+" "+B+"NODES"+X+"   "+B+str(nn)+X+D+" reg · "+X+B+str(tot_panes)+X+D+" panes · "+X
            +(R if tot_busy else B)+str(tot_busy)+X+D+" busy · "+X+(Y if tot_q else B)+str(tot_q)+X+D+" queued"+X))
if nodes: L.append(sep())
for n in nodes:
    panes = state[n].get("panes",{}); pend = len(queue.get(n,[]))
    busy = sum(1 for p in panes.values() if p.get("busy")); idle = len(panes)-busy
    claude = sum(1 for p in panes.values() if (p.get("cmd")=="claude"))
    m = metas[n]; sha = m.get("sha",""); br = m.get("branch",""); dirty = m.get("dirty")
    if not sha:
        gb = D+"@??????"+X
    else:
        col = G if (sha==REF_SHA and (br==REF_BRANCH or not br)) else R
        star = (R+"*"+X) if dirty else ""
        if br and br != REF_BRANCH:
            gb = Y+fit(br,9)+X+D+"@"+X+col+sha+X+star      # off-branch: name@sha
        else:
            gb = col+"@"+sha+X+star                         # on ref branch: @sha
    dot = (G+"●"+X) if idle>0 else (Y+"●"+X)
    warn = ("  "+Y+"⚠"+X) if (busy and idle==0) else ""
    gbpad = " "*max(0, 10-vis(gb))    # git badge carries ANSI → pad by visible width
    L.append(row(dot+" "+B+f"{fit(n,13):<13}"+X+" "+gb+gbpad
                 +" "+f"{len(panes):>2}"+D+"p"+X+" "+G+f"{idle:>2}i"+X+D+"/"+X+(R if busy else D)+f"{busy}b"+X
                 +"  "+(C if claude else D)+f"{claude}cl"+X+warn))
L.append("╰"+dash(W-2)+"╯")
print("\n".join(L))
PY
}

if [ "${1:-}" = --watch ]; then
  iv="${2:-5}"
  # Time-boxed frames: if the RPC / firewall probe hangs, the subprocess is killed
  # (FRAME_TIMEOUT, default 12s), we paint a "retrying" line, and the loop keeps
  # going — the watch can never freeze and always reflects recovery within ~one tick.
  B=$'\033[1m'; C=$'\033[36m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
  while true; do
    c="$(tput cols 2>/dev/null || echo 78)"
    f="$(env DASH_COLS="$c" timeout "${FRAME_TIMEOUT:-12}" bash "$SELF" 2>/dev/null)"
    [ -n "$f" ] || f="${B}${C}tcpuxdo fleet${X}  ${Y}⏳ relay slow/unreachable — retrying…${X}  ${D}$(date '+%H:%M:%S')${X}"
    clear; printf '%s\n' "$f"
    sleep "$iv"
  done
else
  frame "${DASH_COLS:-$(tput cols 2>/dev/null || echo 78)}"; echo
fi
