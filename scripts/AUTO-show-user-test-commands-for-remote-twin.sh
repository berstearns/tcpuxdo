#!/usr/bin/env bash
# Print project-specific commands; deliberately does not run them.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${1:-}"
project_dir="$("$here/AUTO-open-fresh-user-checkout-for-remote-twin.sh" "$profile" --path)"
printf '\nUSER CHECKOUT: %s\nRun commands from this directory. Review the project README first.\n\n' "$project_dir"
case "$profile" in
  gengecerr|gengecerr-dev|gengecerr-pipeline-running)
    printf '%s\n' 'Pipeline: inspect README.md and scripts/run_pipeline.sh in this fresh checkout.' 'Guided reproducibility: inspect scripts/AUTO-fresh-clone-local-mimic.sh and pass a new run directory.' 'Use new run data/output directories; record the Git SHA and exact command before comparing results.' ;;
  gengecerr-paper)
    printf '%s\n' 'Paper: inspect the committed paper instructions and verify claims against a fresh pipeline run and its outputs.' ;;
  app7|app9|app11|app303-get-my-audio-android)
    printf '%s\n' 'Android user path: (1) download a published APK when available, then install and launch on the selected USB device or emulator; (2) optionally build from this checkout; (3) run UI automation from the ui window.' 'List devices first: adb devices -l' "Download or install: $here/AUTO-download-install-and-launch-user-apk.sh $profile APK_URL_OR_FILE DEVICE_SERIAL" 'Choose the exact serial; do not assume the first device.'
    case "$profile" in
      app303-get-my-audio-android)
        printf '%s\n' 'Build: ./scripts/AUTO-android-build.sh debug' 'Install/launch: ./scripts/AUTO-android-install-launch.sh SERIAL [APK_PATH]' 'UI automation: ./scripts/AUTO-maestro-run.sh (read its header for device arguments)' ;;
      app11)
        printf '%s\n' 'Build/installation: inspect the app11 Android project README and scripts before running.' 'UI automation: cd androidApp/maestro && ./run-all.sh (targets its documented AVD).' ;;
      app7)
        printf '%s\n' 'Build/installation: inspect this checkout and its app7 Android build guide.' 'UI automation: inspect the app7 Maestro automation project and its run-all.sh; run only after confirming the selected device.' ;;
      app9)
        printf '%s\n' 'Build/installation/UI automation: inspect the app9 README and tracked scripts in this checkout; no verified one-command runner is recorded for this profile yet.' ;;
    esac ;;
  duolingo)
    printf '%s\n' 'Guided user run: inspect versions/v8/README.md, then versions/v8/bin/duo doctor and the documented launcher.' 'Use fresh data paths; do not take over an existing browser, sink, or TUI session without owner direction.' ;;
  wedding-meta)
    printf '%s\n' 'Deployment test: follow committed setup guides from this fresh checkout; keep build and cloud resources separate from the developer run.' ;;
  *) printf '%s\n' 'Use the fresh checkout to follow its own setup guide and verify the delivered feature as a user.' ;;
esac
printf '\nRole guide: %s/../config/user-workflows/%s.md (default.md if absent)\n' "$here" "$profile"
