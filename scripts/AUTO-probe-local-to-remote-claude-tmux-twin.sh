#!/usr/bin/env bash
# Descriptive entrypoint for AUTO-tcx-remote-pair-verify.sh. Arguments and exit status pass through.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/AUTO-tcx-remote-pair-verify.sh" "$@"
