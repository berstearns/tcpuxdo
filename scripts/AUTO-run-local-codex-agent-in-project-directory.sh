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
case "$profile" in
    rag-papers-gcp-repo|wedding-meta)
        instruction="${2:-/home/b/p/all-my-tiny-projects/claude-rules/instructions/$profile-local-manager.md}" ;;
    *)
        instruction="${2:-/home/b/p/all-my-tiny-projects/claude-rules/instructions/$profile-local-manager.md}"
        [[ -s "$instruction" ]] || instruction="/home/b/p/all-my-tiny-projects/claude-rules/instructions/remote-twin-local-manager.md" ;;
esac
if [[ ! -s "$instruction" ]]; then
    echo "local Codex instruction .md is missing: $instruction"
    exec "${SHELL:-/bin/bash}"
fi
codex --dangerously-bypass-approvals-and-sandbox -C "$project_dir" \
    "Read $instruction and follow it. Report if you cannot read it."
result=$?
echo "Codex exited with status $result; shell kept open in $project_dir"
exec "${SHELL:-/bin/bash}"
