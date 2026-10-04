#!/usr/bin/env bash
# Run the selected local agent in a separate user checkout with a role prompt.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/twin-agent-options.sh"
profile="${1:-}"
if ! project_dir="$("$here/AUTO-open-fresh-user-checkout-for-remote-twin.sh" "$profile" --path)"; then
    cd "${TCX_USER_RUNS_DIR:-$HOME/runs}" 2>/dev/null || cd "$HOME"
    echo "fresh user checkout unavailable for $profile; agent not started"
    exec "${SHELL:-/bin/bash}"
fi
twin_options_load "$profile" || exec "${SHELL:-/bin/bash}"
instruction="$here/../config/user-workflows/$profile.md"
[[ -s "$instruction" ]] || instruction="$here/../config/user-workflows/default.md"
export PATH="$HOME/.local/bin:$PATH"
cd "$project_dir" || exec "${SHELL:-/bin/bash}"
twin_agent_argv "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT"
[[ "$TWIN_LOCAL_AGENT" == codex ]] && TWIN_AGENT_ARGS+=(-C "$project_dir")
printf 'user agent: %s %s/%s in %s\n' "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT" "$project_dir"
"${TWIN_AGENT_ARGS[@]}" "Read $instruction and follow it as the independent user/tester. The checkout is $project_dir. Report if you cannot read the instruction."
result=$?
echo "user agent exited with status $result; shell kept open in $project_dir"
exec "${SHELL:-/bin/bash}"
