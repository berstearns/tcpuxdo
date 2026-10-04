#!/usr/bin/env bash
# Start the selected local manager agent in a remote twin's project directory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/twin-agent-options.sh"
profile="${1:-}"
dirs="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
project_dir="$(awk -F '\t' -v p="$profile" '$1==p {print $2; exit}' "$dirs" 2>/dev/null)"
if [[ -z "$profile" || ! -d "$project_dir" ]]; then
    echo "local manager project directory is missing for profile '$profile'"
    exec "${SHELL:-/bin/bash}"
fi
if ! twin_options_load "$profile"; then
    echo "invalid agent options for profile '$profile'"
    exec "${SHELL:-/bin/bash}"
fi
instruction="${2:-/home/b/p/all-my-tiny-projects/claude-rules/instructions/$profile-local-manager.md}"
if [[ ! -s "$instruction" ]]; then
    case "$profile" in
        rag-papers-gcp-repo|wedding-meta) ;;
        *) instruction="/home/b/p/all-my-tiny-projects/claude-rules/instructions/remote-twin-local-manager.md" ;;
    esac
fi
if [[ ! -s "$instruction" ]]; then
    echo "local manager instruction .md is missing: $instruction"
    exec "${SHELL:-/bin/bash}"
fi
export PATH="$HOME/.local/bin:$PATH"
cd "$project_dir" || exec "${SHELL:-/bin/bash}"
twin_agent_argv "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT"
if ! command -v "${TWIN_AGENT_ARGS[0]}" >/dev/null; then
    echo "local $TWIN_LOCAL_AGENT command is unavailable in PATH"
    exec "${SHELL:-/bin/bash}"
fi
if [[ "$TWIN_LOCAL_AGENT" == codex ]]; then TWIN_AGENT_ARGS+=(-C "$project_dir"); fi
printf 'local manager: %s %s/%s in %s\n' "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT" "$project_dir"
"${TWIN_AGENT_ARGS[@]}" "Read $instruction and follow it. Report if you cannot read it."
result=$?
echo "$TWIN_LOCAL_AGENT exited with status $result; shell kept open in $project_dir"
exec "${SHELL:-/bin/bash}"
