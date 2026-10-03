#!/usr/bin/env bash
# Descriptive entrypoint for AUTO-tcx-remote-shell-twin.sh. Arguments and exit status pass through.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/AUTO-tcx-remote-shell-twin.sh" "$@"
