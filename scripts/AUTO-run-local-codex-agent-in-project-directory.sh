#!/usr/bin/env bash
# Legacy entrypoint; local manager can now be Codex or Claude Code.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/AUTO-run-local-manager-agent-in-project-directory.sh" "$@"
