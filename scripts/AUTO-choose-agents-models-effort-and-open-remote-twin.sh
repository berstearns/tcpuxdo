#!/usr/bin/env bash
# Save per-project local/remote agent choices and open its i3minator twin.
# A dry run prints the resolved selection and starts nothing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/twin-agent-options.sh"

usage() {
    cat <<'EOF'
usage: AUTO-choose-agents-models-effort-and-open-remote-twin.sh PROFILE [options]
  --local-agent claude|codex    --local-model MODEL    --local-effort LEVEL
  --remote-agent claude|codex   --remote-model MODEL   --remote-effort LEVEL
  --reset   restore the built-in defaults for this profile
  --dry-run print the selected commands; do not save or start anything

Defaults: local codex gpt-6-sol/medium; remote claude sonnet/medium.
Choices are saved per profile for future i3minator launches.
Options apply when new agent processes start; this command will refuse to
change choices while the local twin tmux session already exists.
EOF
}

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }
profile="${1:-}"
[[ -n "$profile" && "$profile" != -* && "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || { usage >&2; exit 64; }
shift
conf="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
awk -F: -v p="$profile" '$1==p{found=1} END{exit !found}' "$conf" || { echo "unknown profile: $profile" >&2; exit 64; }
twin_options_load "$profile"
original_local_agent="$TWIN_LOCAL_AGENT"
original_remote_agent="$TWIN_REMOTE_AGENT"
dry=0
changed=0
local_model_set=0; local_effort_set=0; remote_model_set=0; remote_effort_set=0
while (( $# )); do
    case "$1" in
        --local-agent|--local-model|--local-effort|--remote-agent|--remote-model|--remote-effort)
            option="$1"; shift
            (( $# )) || { echo "missing value for $option" >&2; exit 64; }
            case "$option" in
                --local-agent) TWIN_LOCAL_AGENT="$1" ;;
                --local-model) TWIN_LOCAL_MODEL="$1"; local_model_set=1 ;;
                --local-effort) TWIN_LOCAL_EFFORT="$1"; local_effort_set=1 ;;
                --remote-agent) TWIN_REMOTE_AGENT="$1" ;;
                --remote-model) TWIN_REMOTE_MODEL="$1"; remote_model_set=1 ;;
                --remote-effort) TWIN_REMOTE_EFFORT="$1"; remote_effort_set=1 ;;
            esac
            changed=1 ;;
        --reset)
            twin_options_defaults
            original_local_agent="$TWIN_LOCAL_AGENT"
            original_remote_agent="$TWIN_REMOTE_AGENT"
            local_model_set=0; local_effort_set=0; remote_model_set=0; remote_effort_set=0
            changed=1 ;;
        --dry-run) dry=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done
if [[ "$TWIN_LOCAL_AGENT" != "$original_local_agent" ]]; then
    twin_agent_defaults "$TWIN_LOCAL_AGENT"
    (( local_model_set )) || TWIN_LOCAL_MODEL="$TWIN_DEFAULT_MODEL"
    (( local_effort_set )) || TWIN_LOCAL_EFFORT="$TWIN_DEFAULT_EFFORT"
fi
if [[ "$TWIN_REMOTE_AGENT" != "$original_remote_agent" ]]; then
    twin_agent_defaults "$TWIN_REMOTE_AGENT"
    (( remote_model_set )) || TWIN_REMOTE_MODEL="$TWIN_DEFAULT_MODEL"
    (( remote_effort_set )) || TWIN_REMOTE_EFFORT="$TWIN_DEFAULT_EFFORT"
fi
twin_options_validate
printf 'local  %s %s/%s\nremote %s %s/%s\n' \
    "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT" \
    "$TWIN_REMOTE_AGENT" "$TWIN_REMOTE_MODEL" "$TWIN_REMOTE_EFFORT"
twin_agent_argv "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT"
printf 'local agent argv: '; printf '%q ' "${TWIN_AGENT_ARGS[@]}"; printf '\n'
twin_agent_argv "$TWIN_REMOTE_AGENT" "$TWIN_REMOTE_MODEL" "$TWIN_REMOTE_EFFORT"
printf 'remote agent argv: '; printf '%q ' "${TWIN_AGENT_ARGS[@]}"; printf '\n'
if (( dry )); then
    printf 'would run: i3minator start remote-%s\n' "$profile"
    exit 0
fi
if (( changed )) && tmux has-session -t "=remote-$profile" 2>/dev/null; then
    echo "local twin remote-$profile already exists; agent changes require a fresh twin session" >&2
    exit 3
fi
if (( changed )); then twin_options_save "$profile"; fi
exec i3minator start "remote-$profile"
