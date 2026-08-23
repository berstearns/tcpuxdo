#!/usr/bin/env bash
#===============================================================================
# WHAT:    phase2-e2e.sh — the NO-CHEAT acceptance test for the m1 cockpit.
#          Proves the full chain with zero transport shortcuts:
#
#            naked archlinux:base container
#              └─ gets EVERYTHING over a LIVE fserve share (curl + i.sh +
#                 payload.tar.zst, profile arch-wsl-fleet: worker + claude +
#                 credential). NO -v mount. NO docker cp. NO local files.
#              └─ its worker polls the REAL relay (TCPUX_HOST from .env,
#                 <relay-host>:9100) and its IP is allowlisted the real
#                 way (role.sh runs `tcpuxdo allow` itself).
#            m1 (this laptop)
#              └─ runs scripts/AUTO-tcx-cockpit.sh — the COMMAND, never i3 —
#                 to create the remote claude session and save the target,
#              └─ sends the sentinel prompt through the relay,
#              └─ captures the container's claude pane and greps the reply.
#
#          PASS = the sentinel reply, read back out of the container's pane.
#          Anything less is FAIL or a named BLOCKED step — never a claimed
#          success (STRICT rules 9/11/12, F22-24).
#
# INPUTS:  --yes            REQUIRED to run: this test spins a live fserve
#                           share (a paid droplet) and drives the real relay.
#                           Without --yes it prints the plan and exits 64.
#          -n, --dry-run    print every command that would run, run nothing
#          --worker NAME    container worker name    (default: dockere2e)
#          --session NAME   remote session name      (default: e2e)
#          --ttl DUR        fserve share TTL         (default: 30m)
#          --keep           leave the container + share up afterwards
#          -h, --help
#
# OUTPUTS: progress on stderr; the FINAL LINE on stdout is exactly
#          "PASS" or "FAIL <named-step>" (GNU §1: stdout is the verdict).
#          exit 0 PASS · 1 FAIL · 64 usage · 69 a dependency/engine missing.
#
# REUSE:   sources /home/b/p/archlinux-transfer/deploy/lib.sh for
#          build_payload / send_cmd / wait_for_marker / parse_share, and runs
#          that repo's container.sh unmodified — held open with an appended
#          sleep so the worker outlives the spin-up (the harness must not
#          patch the payload; holding stdin open is a runner concern).
#          The m1 half is scripts/AUTO-tcx-cockpit.sh and tcx.sh — engines,
#          not reimplementations (STRICT rule 17).
#===============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
XFER="${XFER_REPO:-/home/b/p/archlinux-transfer}"
COCKPIT="$ROOT/scripts/AUTO-tcx-cockpit.sh"
SENTINEL="M1_TO_DOCKER_OK"

WNAME="dockere2e"
RSESS="e2e"
TTL="30m"
YES=0; DRY=0; KEEP=0
E2E_SESS="phase2e2e"          # local tmux session holding the two driver panes
CONTAINER="nakedarch-e2e"

note() { printf 'e2e: %s\n' "$*" >&2; }
fail() { printf 'e2e: FAIL at %s — %s\n' "$1" "$2" >&2; printf 'FAIL %s\n' "$1"; cleanup; exit 1; }
usage_die() { printf 'e2e: %s\n' "$*" >&2; exit 64; }

while [[ $# -gt 0 ]]; do case "$1" in
    --yes)       YES=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    --worker)    [[ $# -ge 2 ]] || usage_die "--worker needs a value"; WNAME="$2"; shift 2 ;;
    --session)   [[ $# -ge 2 ]] || usage_die "--session needs a value"; RSESS="$2"; shift 2 ;;
    --ttl)       [[ $# -ge 2 ]] || usage_die "--ttl needs a value"; TTL="$2"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_die "unknown option '$1' — try --help" ;;
esac; done

run() {  # every side-effecting command routes through here for --dry-run
    if (( DRY )); then printf '  DRY %s\n' "$*" >&2; return 0; fi
    "$@"
}

cleanup() {
    (( KEEP )) && { note "--keep: leaving the container and share up"; return 0; }
    (( DRY )) && return 0
    docker kill "$CONTAINER" >/dev/null 2>&1
    tmux kill-session -t "=$E2E_SESS" 2>/dev/null
    note "cleanup: container killed, driver session gone. The fserve share"
    note "expires by TTL ($TTL); to drop it now run: fserve down"
    return 0
}

# ── preflight: name every missing piece before spending anything ────────────
for c in docker tmux jq curl fserve tps; do
    command -v "$c" >/dev/null || { printf 'FAIL preflight\n'; usage_die "'$c' not on PATH"; }
done
[[ -x "$COCKPIT" ]]            || { printf 'FAIL preflight\n'; usage_die "cockpit missing: $COCKPIT"; }
[[ -r "$XFER/deploy/lib.sh" ]] || { printf 'FAIL preflight\n'; usage_die "phase-1 harness missing: $XFER/deploy/lib.sh"; }
docker info >/dev/null 2>&1    || { printf 'FAIL preflight\n'; usage_die "cannot talk to the docker daemon"; }
"$ROOT/tcpuxdo" --op state >/dev/null 2>&1 \
    || { printf 'FAIL preflight\n'; usage_die "relay did not answer --op state (CANNOT TELL, exit 69)"; }

if (( ! YES && ! DRY )); then
    note "this test SPENDS: a live fserve share (paid droplet) + real relay traffic."
    note "plan: payload(arch-wsl-fleet) -> fserve share $TTL -> naked archlinux:base"
    note "      -> worker '$WNAME' on the real relay -> cockpit -> sentinel -> capture."
    usage_die "re-run with --yes to spend that (or -n to preview)"
fi

# lib.sh provides: REPO(=XFER) build_payload send_cmd wait_for_marker parse_share
# shellcheck source=/dev/null
. "$XFER/deploy/lib.sh"

# ── the two driver panes, created titled, resolved to %IDs — never indexes ──
step() { printf '\n── %s\n' "$*" >&2; }

step "0. driver panes (session $E2E_SESS)"
if ! tmux has-session -t "=$E2E_SESS" 2>/dev/null; then
    run tmux new-session -d -s "$E2E_SESS" -c "$XFER"
    run tmux split-window -d -t "=$E2E_SESS:" -c "$XFER"
fi
if (( ! DRY )); then
    mapfile -t PANES < <(tmux list-panes -s -t "=$E2E_SESS" -F '#{pane_id}')
    [[ ${#PANES[@]} -ge 2 ]] || fail driver-panes "could not create two panes"
    tmux select-pane -t "${PANES[0]}" -T nakedrun
    tmux select-pane -t "${PANES[1]}" -T nakeddocker
    SERVE="$(tps -s "$E2E_SESS" -r nakedrun)"   || fail driver-panes "tps cannot resolve nakedrun"
    TEST="$(tps -s "$E2E_SESS" -r nakeddocker)" || fail driver-panes "tps cannot resolve nakeddocker"
    note "serve=$SERVE test=$TEST"
else
    SERVE="%DRY-serve"; TEST="%DRY-test"
fi

RUN_ID="$(new_run_id)"
note "run id: $RUN_ID"

step "1. payload (arch-wsl-fleet: worker + claude + credential)"
if (( DRY )); then note "DRY build_payload arch-wsl-fleet"; else
    build_payload arch-wsl-fleet || fail payload "build_payload failed"
fi

step "2. fserve share ($TTL) from pane nakedrun"
if (( DRY )); then
    note "DRY fserve share $TTL $XFER/stage0/i.sh $XFER/payload.tar.zst"
else
    marker="READY-$RUN_ID"
    send_cmd "$SERVE" "fserve share $TTL $XFER/stage0/i.sh $XFER/payload.tar.zst"
    send_cmd "$SERVE" "echo $marker"
    wait_for_marker "$SERVE" "$marker" 60         || fail fserve "pane nakedrun not responding"
    wait_for_marker "$SERVE" 'fserve is up — READY' 600 || fail fserve "share never READY"
    parse_share "$SERVE"                          || fail fserve "cannot parse the share block"
    for cn in "$SHARE_CN_I" "$SHARE_CN_P"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -u "fdrop:$SHARE_PASS" -k \
               --max-time 20 "https://$SHARE_HOST:47824/$cn")
        [[ "$code" == 200 ]] || fail fserve "codename $cn returned HTTP $code"
    done
    note "share up and both URLs return 200"
fi

step "3. naked archlinux:base container — fserve transport ONLY, held open"
# container.sh exits when its stdin script ends; append a hold so the worker
# and the claude pane OUTLIVE the spin-up. No -v, no docker cp, no --network
# tricks: the docker default bridge and the fserve URLs are all it gets.
HOLD='echo E2E_HOLDING; sleep 3600'
DOCKER_CMD="cat $XFER/deploy/container.sh <(printf '%s\n' '$HOLD') | \
docker run --rm -i --name $CONTAINER -e SPINUP_RUN_ID=$RUN_ID \
-e FSERVE_BASE=https://\$SHARE_HOST:47824 -e FSERVE_AUTH=fdrop:\$SHARE_PASS \
-e FSERVE_CN_I=\$SHARE_CN_I -e FSERVE_CN_P=\$SHARE_CN_P \
-e DISTRO=arch-wsl-fleet -e TCPUX_WORKER=$WNAME archlinux:base bash -s"
if (( DRY )); then note "DRY $DOCKER_CMD"; else
    send_cmd "$TEST" "SHARE_HOST=$SHARE_HOST SHARE_PASS=$SHARE_PASS SHARE_CN_I=$SHARE_CN_I SHARE_CN_P=$SHARE_CN_P; $DOCKER_CMD"
    wait_for_marker "$TEST" "DONE $RUN_ID" 1200 || fail container "no spin-up verdict in 20m"
    wait_for_marker "$TEST" "E2E_HOLDING" 60    || fail container "container did not hold open"
fi

step "4. the container worker appears in live relay state"
if (( ! DRY )); then
    t=0; until "$ROOT/tcpuxdo" --op state 2>/dev/null | jq -e --arg w "$WNAME" '.state | has($w)' >/dev/null; do
        (( t >= 300 )) && fail worker-registration "'$WNAME' never appeared in --op state (allowlist? role.sh --no-start?)"
        sleep 5; t=$((t+5))
    done
    note "worker '$WNAME' is registered (its IP passed the real allowlist)"
fi

step "5. m1 runs THE COMMAND (never i3): cockpit builds the remote claude session"
# TCX_COCKPIT_WAIT raised: a container fresh off its install answers its first
# ops slowly (pacman cache flush, first tmux server start); 25s was observed
# too short for the pane to reach the registry, 120s covers the cold start.
# Retried up to 3×: the cockpit is idempotent (an existing session is reused,
# nothing duplicated), and a transient m1→relay blip (observed: errno 113
# mid-run, gone seconds later) must not sink a 15-minute container build.
cockpit_ok=0
for attempt in 1 2 3; do
    if run env NO_COLOR=1 TCX_COCKPIT_WAIT=120 "$COCKPIT" --tty --no-local \
            -w "$WNAME" -s "$RSESS" -d '~'; then
        cockpit_ok=1; break
    fi
    note "cockpit attempt $attempt failed — retrying in 15s (idempotent reuse)"
    sleep 15
done
if (( ! cockpit_ok )); then
    note "diagnosis — live registry for $WNAME:"
    "$ROOT/tcpuxdo" --op state 2>/dev/null \
        | jq -r --arg w "$WNAME" '(.state[$w].panes // {}) | keys[]' \
        | sed 's/^/e2e:   /' >&2
    note "diagnosis — container worker pane tail:"
    docker exec "$CONTAINER" su - b -c \
        'tmux capture-pane -p -t tcpuxdo-worker -S -30 2>/dev/null' 2>/dev/null \
        | tail -15 | sed 's/^/e2e:   /' >&2
    fail cockpit "AUTO-tcx-cockpit.sh failed against worker $WNAME"
fi

step "6. sentinel through the relay"
if (( ! DRY )); then
    TARGET_LINE="$("$COCKPIT" --print-target)" || fail target "cockpit saved no target"
    note "target: $TARGET_LINE"
    T_PANE="${TARGET_LINE#*	}"
    # Keys sent into a still-starting TUI are silently dropped (STRICT A4), so
    # do not sleep-and-hope: wait until the registry reports the pane's command
    # IS claude. First start on a cold container takes well over a minute.
    t=0
    until "$ROOT/tcpuxdo" --op state 2>/dev/null \
          | jq -e --arg w "$WNAME" --arg p "$T_PANE" \
               '.state[$w].panes[$p].cmd == "claude"' >/dev/null; do
        (( t >= 300 )) && {
            note "diagnosis — pane cmd right now:"
            "$ROOT/tcpuxdo" --op state 2>/dev/null \
                | jq -r --arg w "$WNAME" --arg p "$T_PANE" '.state[$w].panes[$p]' >&2
            fail claude-start "pane $T_PANE never reported cmd=claude within 5m"
        }
        sleep 10; t=$((t+10))
    done
    note "pane $T_PANE reports cmd=claude — safe to type"
    sleep 5   # let the TUI finish drawing after the process appears
    run "$ROOT/tcx.sh" send "Reply with exactly: $SENTINEL" \
        || fail send "tcx.sh send failed"
fi

step "7. PROOF — read the reply out of the container's claude pane"
if (( DRY )); then
    note "DRY docker exec $CONTAINER su - b -c 'tmux capture-pane …' | grep $SENTINEL"
    # A dry run proves NOTHING end-to-end; saying PASS here would be the green
    # line that lies (STRICT rule 11). The verdict is explicit non-proof.
    printf 'DRY-RUN-ONLY\n'; exit 0
fi
t=0; got=""
while (( t < 300 )); do
    got="$(docker exec "$CONTAINER" su - b -c \
          "tmux capture-pane -p -t '=$RSESS' -S -200 -J" \
          | grep -F "$SENTINEL" | grep -cv "Reply with exactly" || true)"
    [[ "${got:-0}" -ge 1 ]] && break
    sleep 10; t=$((t+10))
done
if [[ "${got:-0}" -ge 1 ]]; then
    note "sentinel reply captured from the container pane:"
    docker exec "$CONTAINER" su - b -c \
        "tmux capture-pane -p -t '=$RSESS' -S -200 -J" \
        | grep -F "$SENTINEL" | sed 's/^/e2e:   /' >&2
    cleanup
    printf 'PASS\n'; exit 0
fi
note "pane tail for diagnosis (last 25 lines):"
docker exec "$CONTAINER" su - b -c \
    "tmux capture-pane -p -t '=$RSESS' -S -200 -J" | tail -25 | sed 's/^/e2e:   /' >&2
fail sentinel-capture "no '$SENTINEL' reply in the container claude pane within 3m"
