#!/usr/bin/env bash
#===============================================================================
# WHAT:    AUTO-tcx-remote-twin-new.sh [-n] [--launch] -l LOCAL_DIR -r REMOTE_DIR
#                                      [-w WORKER] <name>
#          create a NEW remote twin "<name>" end to end:
#            1. LOCAL : mkdir -p LOCAL_DIR
#            2. config: profile line   <name>:<worker>:<name>:<REMOTE_DIR>
#                       local-dir line <name><TAB><LOCAL_DIR>
#               (refuses if <name> already exists — never overwrites a twin)
#            3. i3minator: ~/.config/i3minator/remote-<name>.yml (generator)
#            4. REMOTE: create tmux session <name> on the worker, then
#               mkdir -p REMOTE_DIR inside it, verified by a sentinel
#            5. --launch: i3minator start remote-<name> (local remote-<name>
#               session with cockpit, manager and shell windows; on the worker,
#               Claude plus separate command and git shells in REMOTE_DIR)
#
# WHY:     2026-10-03, Bernardo: "show me the bash script to create a new twin
#          rag-papers-gcp in a target dir here and in the remote, and create the
#          dirs recursively if they do not exist". One command instead of
#          hand-editing two config files and typing on the worker.
#
# INPUTS:  <name>        twin name = profile = remote session (A-Z a-z 0-9 . _ -)
#          -l LOCAL_DIR  project dir on this laptop (created with mkdir -p)
#          -r REMOTE_DIR project dir on the worker, e.g. ~/repos/<name>
#                        (created with mkdir -p; ~ is the worker user's home)
#          -w WORKER     worker name (default: the only LIVE worker; ambiguous → error)
#          --launch      also open it now through i3minator
#          -n            dry run: print every step, change nothing
#
# OUTPUTS: stdout "twin-new<TAB><name><TAB>OK|FAIL<TAB>detail"
#          exit 0 ok · 1 failure · 2 name already exists · 3 relay/worker
#          unreachable · 64 usage
#
# RE-RUN SAFETY: refuses an existing name (exit 2). The remote mkdir -p is
#          idempotent; a remote session that already exists is reused.
#===============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TCPUXDO="$HERE/../tcpuxdo"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
DIRS="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
DEAD="${TCX_STATUS_DEAD_SECS:-180}"

DRY=0; LAUNCH=0; LD=""; RD=""; W=""
help(){ cat <<'EOF'
AUTO-tcx-remote-twin-new.sh — create a NEW remote twin in one command:
  a project dir HERE + a project dir on the WORKER (both mkdir -p),
  a claude agent on the worker, and a menu entry remote-<name> in $mod+Ctrl+x.

USAGE
  AUTO-tcx-remote-twin-new.sh [-n] [--launch] -l LOCAL_DIR -r REMOTE_DIR [-w WORKER] <name>

EXAMPLES (copy, change the names, run)
  T=/home/b/p/tcpuxdo/scripts/AUTO-tcx-remote-twin-new.sh

  # 1. ALWAYS look first: -n prints every step and changes nothing
  $T -n -l ~/p/all-my-tiny-projects/playground/naked-gcp/rag-papers-gcp \
        -r '~/repos/rag-papers-gcp'  rag-papers-gcp

  # 2. create it and open it right away (wezterm window via i3minator)
  $T --launch -l ~/p/all-my-tiny-projects/playground/naked-gcp/rag-papers-gcp \
              -r '~/repos/rag-papers-gcp'  rag-papers-gcp

  # 3. create it now, open it later from the menu ($mod+Ctrl+x → remote-rag-papers-gcp)
  $T -l ~/p/research-sketches/my-new-idea  -r '~/repos/my-new-idea'  my-new-idea

  # 4. pick the worker yourself (needed when more than one worker is live)
  $T -w do-app11 -l ~/p/writings/thesis-ch7  -r '~/repos/thesis-ch7'  thesis-ch7

  # 5. after creating: is it working?
  /home/b/p/tcpuxdo/scripts/AUTO-tcx-remote-status.sh

  # 6. wrong dir / wrong worker? UNDO it on both sides (files are kept;
  #    --rmdir only removes an EMPTY local dir), then create it again
  /home/b/p/tcpuxdo/scripts/AUTO-tcx-remote-twin-rm.sh --rmdir rag-papers-gcp

  NOTE do-app11: ~/p is NOT writable for the worker user — use '~/repos/<name>'.

OPTIONS
  <name>         twin name (letters, digits, . _ -). Becomes: menu entry remote-<name>,
                 local tmux session remote-<name>, remote tmux session <name>.
  -l LOCAL_DIR   project dir on THIS laptop. Created if missing (mkdir -p).
  -r REMOTE_DIR  project dir on the WORKER. Created if missing (mkdir -p).
                 Quote it ('~/repos/x') so ~ means the WORKER's home, not yours.
  -w WORKER      worker name (see: relay-topo workers). Default: the only live one.
  --launch       also open the twin now (i3minator start remote-<name>).
  -n             dry run: print every step, change nothing.
  -h, --help     this text.

WHAT YOU GET
  here:   tmux session remote-<name>  →  tcx-send (type a prompt for claude, Enter)
                                         tcx-stream (watch claude on the worker)
                                         window "shell": sh-send / sh-stream (bash on the worker)
  worker: tmux session <name> with claude --dangerously-skip-permissions in REMOTE_DIR

EXIT CODES
  0 ok · 1 failure · 2 name already exists (never overwritten) · 3 relay/worker down · 64 usage

FILES IT CHANGES
  ~/.config/tcx-cockpit/profiles.conf     one new line  <name>:<worker>:<name>:<REMOTE_DIR>
  ~/.config/tcx-cockpit/local-dirs.tsv    one new line  <name><TAB><LOCAL_DIR>
  ~/.config/i3minator/remote-<name>.yml   new (generated, do not edit)
EOF
}
usage(){ echo "usage: AUTO-tcx-remote-twin-new.sh [-n] [--launch] -l LOCAL_DIR -r REMOTE_DIR [-w WORKER] <name>   (examples: -h)" >&2; exit 64; }
while (( $# )); do case "$1" in
    -n) DRY=1; shift ;; --launch) LAUNCH=1; shift ;;
    -l) LD="${2:-}"; shift 2 ;; -r) RD="${2:-}"; shift 2 ;; -w) W="${2:-}"; shift 2 ;;
    -h|--help) help; exit 0 ;; -*) usage ;;
    *) NAME="$1"; shift ;;
esac; done
[[ -n "${NAME:-}" && -n "$LD" && -n "$RD" ]] || usage
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad name '$NAME' (A-Z a-z 0-9 . _ -)" >&2; exit 64; }
[[ "$RD" != *:* && "$LD" != *$'\t'* ]] || { echo "dirs must not contain ':' (remote) or TAB (local)" >&2; exit 64; }
for c in jq timeout tmux i3minator; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 64; }; done
out(){ printf 'twin-new\t%s\t%s\t%s\n' "$NAME" "$1" "$2"; }
step(){ echo "▸ $*" >&2; }

grep -v '^[[:space:]]*#' "$CONF" | grep -q "^${NAME}:" && { out FAIL "profile '$NAME' already exists in $CONF"; exit 2; }
LD="$(realpath -m "${LD/#\~/$HOME}")"

# worker: given, else the single live one
STATE="$(timeout 60 "$TCPUXDO" --op state 2>/dev/null)"
jq -e .state >/dev/null 2>&1 <<<"$STATE" || { out FAIL "relay unreachable (tcpuxdo --op state)"; exit 3; }
if [[ -z "$W" ]]; then
    mapfile -t live < <(jq -r --argjson d "$DEAD" '.state | to_entries[] | select((now - (.value.last_update//0)) < $d) | .key' <<<"$STATE")
    (( ${#live[@]} == 1 )) || { out FAIL "pick a worker with -w (live: ${live[*]:-none})"; exit 64; }
    W="${live[0]}"
fi
age="$(jq -r --arg w "$W" '(now - (.state[$w].last_update // 0))|floor' <<<"$STATE")"
(( age < DEAD )) || { out FAIL "worker $W is not live (${age}s since last update)"; exit 3; }

if (( DRY )); then
    step "mkdir -p $LD"
    step "append to $CONF: $NAME:$W:$NAME:$RD"
    step "append to $DIRS: $NAME<TAB>$LD"
    step "AUTO-tcx-remote-pair-gen.sh $NAME → ~/.config/i3minator/remote-$NAME.yml"
    step "tcpuxdo --op create-session --worker $W --session $NAME; then in $NAME:0:0: mkdir -p $RD"
    (( LAUNCH )) && step "i3minator start remote-$NAME"
    out OK "dry run"; exit 0
fi

# 1 — local dir
step "local: mkdir -p $LD"; mkdir -p "$LD" || { out FAIL "mkdir -p $LD"; exit 1; }

# 2 — config (append; the name was checked absent above)
step "config: profile + local dir"
printf '%s:%s:%s:%s\n' "$NAME" "$W" "$NAME" "$RD" >> "$CONF"
printf '%s\t%s\n' "$NAME" "$LD" >> "$DIRS"

# 3 — i3minator launcher
step "i3minator: remote-$NAME.yml"
"$HERE/AUTO-tcx-remote-pair-gen.sh" "$NAME" >&2 || { out FAIL "generator failed"; exit 1; }

# 4 — remote session + mkdir -p, verified by a sentinel in the capture
step "remote: session $NAME on $W, mkdir -p $RD"
PANE="$NAME:0:0"
if ! jq -e --arg w "$W" --arg p "$PANE" '.state[$w].panes[$p]' >/dev/null <<<"$STATE"; then
    timeout 30 "$TCPUXDO" --op create-session --worker "$W" --session "$NAME" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        sleep 3
        timeout 15 "$TCPUXDO" --op state 2>/dev/null | jq -e --arg w "$W" --arg p "$PANE" '.state[$w].panes[$p]' >/dev/null 2>&1 && break
    done
fi
MARK="TWINNEW$$"
# Both outcomes print a marker, so a refusal (e.g. ~/p not writable on
# do-app11: "Permission denied", 2026-10-03) fails FAST with the reason.
timeout 30 "$TCPUXDO" --no-cascade -w "$W" -p "$PANE" -c "mkdir -p $RD && cd $RD && echo ${MARK}_OK \$(pwd) || echo ${MARK}_ERR" >/dev/null 2>&1 \
    || { out FAIL "could not type into $W $PANE (busy or missing)"; exit 1; }
for _ in $(seq 1 15); do
    sleep 3
    cap="$(timeout 40 "$TCPUXDO" read -w "$W" -p "$PANE" 2>/dev/null)" || continue
    got="$(grep -o "^${MARK}_OK .*" <<<"$cap" | tail -1)"
    [[ -n "$got" ]] && break
    if grep -q "^${MARK}_ERR" <<<"$cap"; then
        why="$(grep -E 'mkdir:|cd:' <<<"$cap" | tail -1)"
        out FAIL "remote mkdir -p $RD refused on $W: ${why:-see $PANE}. Undo: $HERE/AUTO-tcx-remote-twin-rm.sh $NAME"; exit 1
    fi
done
[[ -n "${got:-}" ]] || { out FAIL "remote mkdir not confirmed in $PANE. Undo: $HERE/AUTO-tcx-remote-twin-rm.sh $NAME"; exit 1; }

# 5 — optional launch
if (( LAUNCH )); then step "launch: i3minator start remote-$NAME"; i3minator start "remote-$NAME" >&2; fi
out OK "local $LD · remote $W:${got#${MARK}_OK } · menu remote-$NAME"
