#!/usr/bin/env bash
# Open the Android user UI pane at the actual automation runner. Runs no flow.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${1:-}"
case "$profile" in
    app7)
        dir=/home/b/p/minimal-android-apps/app7-maestro-automation
        runner='./run-all.sh'
        ;;
    app11)
        dir=/home/b/p/minimal-android-apps/app11-research-reader-android/mono/app/src/androidApp/maestro
        runner='./run-all.sh'
        ;;
    app303-get-my-audio-android)
        checkout="$("$here/AUTO-open-fresh-user-checkout-for-remote-twin.sh" "$profile" --path)"
        dir="$checkout/auto-app"
        runner='./scripts/AUTO-maestro-run.sh'
        ;;
    app9)
        dir="$("$here/AUTO-open-fresh-user-checkout-for-remote-twin.sh" "$profile" --path)"
        runner='No tracked UI automation runner found for app9; inspect this checkout.'
        ;;
    *) echo "usage: AUTO-open-android-user-ui-automation-shell.sh app7|app9|app11|app303-get-my-audio-android" >&2; exit 64 ;;
esac
[[ -d "$dir" ]] || { echo "UI automation directory missing: $dir" >&2; exit 1; }
cd "$dir"
printf 'Android UI automation for %s\nDirectory: %s\nRunner: %s\nList devices: adb devices -l\nReview runner device targeting before running it.\n' "$profile" "$dir" "$runner"
exec "${SHELL:-/bin/bash}"
