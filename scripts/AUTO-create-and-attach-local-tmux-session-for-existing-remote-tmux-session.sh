#!/usr/bin/env bash
#===============================================================================
# WHAT: Create or reuse the LOCAL tmux session for an EXISTING remote twin,
#       then enter that local session. This does not create a new twin profile.
# WHY:  The remote-twin-new script already wrote the profile and remote session;
#       a separate, plainly named command is needed when only the local tmux
#       session is missing.
# INPUTS: One profile name from ~/.config/tcx-cockpit/profiles.conf.
# OUTPUTS: An attached/switched tmux client on remote-<profile>, or a specific
#          error before any local session is created.
# USAGE: scripts/AUTO-create-and-attach-local-tmux-session-for-existing-remote-tmux-session.sh rag-papers-gcp-repo
# RE-RUN SAFETY: The underlying launcher reuses a valid existing local session.
#                A missing/stale remote session is rejected before launch.
#===============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
PROFILE="${1:-}"

if [[ "$#" -ne 1 || ! "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "usage: $(basename "$0") <existing-remote-twin-profile>" >&2
    exit 64
fi
for command in jq timeout tmux; do
    command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 64; }
done
[[ -r "$CONF" ]] || { echo "profile file missing: $CONF" >&2; exit 1; }

line="$(awk -F: -v name="$PROFILE" '$1 == name {print; exit}' "$CONF")"
[[ -n "$line" ]] || { echo "remote twin profile '$PROFILE' does not exist in $CONF" >&2; exit 1; }
IFS=: read -r _ worker remote_session _ <<<"$line"
[[ -n "$worker" && -n "$remote_session" ]] || {
    echo "profile '$PROFILE' has no worker or remote session" >&2
    exit 1
}

state="$(timeout 45 "$HERE/../tcpuxdo" --op state)" || {
    echo "could not read relay state; local session not started" >&2
    exit 3
}
if ! jq -e --arg worker "$worker" --arg prefix "$remote_session:" '
    (.state[$worker] // {}) as $record |
    ((now - ($record.last_update // 0)) <= 60)
    and ([($record.panes // {}) | keys[] | select(startswith($prefix))] | length > 0)
  ' >/dev/null <<<"$state"; then
    echo "remote tmux session '$remote_session' on worker '$worker' is absent or stale; local session not started" >&2
    exit 3
fi

echo "remote tmux session '$remote_session' is live on '$worker'; opening local 'remote-$PROFILE'"
exec "$HERE/AUTO-create-or-reuse-and-enter-local-tmux-session-for-remote-twin.sh" "$PROFILE"
