#!/usr/bin/env bash
# Print project-specific commands; deliberately does not run them.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${1:-}"
project_dir="$("$here/AUTO-open-fresh-user-checkout-for-remote-twin.sh" "$profile" --path)"
printf '\nUSER CHECKOUT: %s\nRun commands from this directory. Review the project README first.\n\n' "$project_dir"
case "$profile" in
  gengecerr|gengecerr-dev|gengecerr-pipeline-running)
    printf '%s\n' 'Pick one exact cell: model family + size, fine-tuned or native, L1/CEFR head or no head, then ONE shard.' 'List shipped cells: python run.py --list' 'Resolve one cell: python run.py CELL --dry-run' 'Run one cell: python run.py CELL --out ~/runs/USER-RUN/out' 'Record the cell config, source SHA, checkpoint, corpus, output, and L1/CEFR head provenance. The base 88-cell CLI does not encode an L1/CEFR head switch: use the separate conditioning pipeline or report this axis as unavailable.' ;;
  gengecerr-paper)
    printf '%s\n' 'Paper: inspect the committed paper instructions and verify claims against a fresh pipeline run and its outputs.' ;;
  app7|app9|app11|app303-get-my-audio-android)
    artifact_app="$profile"; [[ "$profile" == app303-get-my-audio-android ]] && artifact_app=app303
    printf '%s\n' 'Android user path: download the newest APK from hetzner:apps/APP/release/, transfer it to this laptop, then install and launch it on the USB phone.' 'List devices: adb devices -l' "Default USB phone and latest Hetzner APK: $here/AUTO-download-install-and-launch-user-apk.sh $profile" "Explicit artifact and emulator: $here/AUTO-download-install-and-launch-user-apk.sh $profile hetzner:apps/$artifact_app/release/FILE.apk emulator-SERIAL" 'Optional: build from the fresh source checkout, then pass the built APK path to the same helper. Use the ui window for automation.'
    case "$profile" in
      app303-get-my-audio-android)
        printf '%s\n' 'Build: ./scripts/AUTO-android-build.sh debug' 'Install/launch: ./scripts/AUTO-android-install-launch.sh SERIAL [APK_PATH]' 'UI automation: ./scripts/AUTO-maestro-run.sh (read its header for device arguments)' ;;
      app11)
        printf '%s\n' 'Build/installation: inspect the app11 Android project README and scripts before running.' 'UI automation: cd androidApp/maestro && ./run-all.sh (targets its documented AVD).' ;;
      app7)
        printf '%s\n' 'Optional build: inspect the fresh app7 checkout and its Android build guide.' 'UI automation: the ui pane opens app7-maestro-automation; use ./run.sh flows/NAME.yaml [data/FILE.tsv].' ;;
      app9)
        printf '%s\n' 'Build/installation/UI automation: inspect the app9 README and tracked scripts in this checkout; no verified one-command runner is recorded for this profile yet.' ;;
    esac ;;
  duolingo)
    printf '%s\n' 'Guided user run: inspect versions/v8/README.md, then versions/v8/bin/duo doctor and the documented launcher.' 'Use fresh data paths; do not take over an existing browser, sink, or TUI session without owner direction.' ;;
  wedding-meta)
    printf '%s\n' 'Deployment test: follow committed setup guides from this fresh checkout; keep build and cloud resources separate from the developer run.' ;;
  linkedin)
    printf '%s\n' 'Goal: annotate feed posts and job posts, collect their data, upload annotations to remote Turso, then query the remote rows and inspect them.' 'The current keyboard prototype only drives a local practice page and has no Turso sink. Compare with the separate linkedin-scraping implementation; report missing end-to-end steps instead of claiming success.' ;;
  *) printf '%s\n' 'Use the fresh checkout to follow its own setup guide and verify the delivered feature as a user.' ;;
esac
printf '\nRole guide: %s/../config/user-workflows/%s.md (default.md if absent)\n' "$here" "$profile"
