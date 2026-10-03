#!/usr/bin/env bash
# Run the local Codex agent for one remote-twin profile in its local project dir.
# Invoked as the command of that twin's visible "codex" tmux window.
set -uo pipefail
profile="${1:-}"
dirs="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
project_dir="$(awk -F '\t' -v p="$profile" '$1==p {print $2; exit}' "$dirs" 2>/dev/null)"
if [[ -z "$profile" || ! -d "$project_dir" ]]; then
    echo "local Codex project directory is missing for profile '$profile'"
    exec "${SHELL:-/bin/bash}"
fi
export PATH="$HOME/.local/bin:$PATH"
cd "$project_dir" || exec "${SHELL:-/bin/bash}"
if ! command -v codex >/dev/null; then
    echo "codex command is unavailable in PATH"
    exec "${SHELL:-/bin/bash}"
fi
codex -C "$project_dir"
result=$?
echo "Codex exited with status $result; shell kept open in $project_dir"
exec "${SHELL:-/bin/bash}"
