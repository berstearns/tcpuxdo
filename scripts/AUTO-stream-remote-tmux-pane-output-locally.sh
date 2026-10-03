#!/usr/bin/env bash
# Descriptive entrypoint for ../setup/tcx-stream.sh. Arguments and exit status pass through.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../setup/tcx-stream.sh" "$@"
