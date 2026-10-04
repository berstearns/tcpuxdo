#!/usr/bin/env bash
# Download (or reuse) an APK, install it on an explicitly selected device,
# and launch its package. This runs only when the user invokes it in the ui pane.
set -euo pipefail
if (( $# != 3 )); then
    echo 'usage: AUTO-download-install-and-launch-user-apk.sh PROFILE APK_URL_OR_FILE DEVICE_SERIAL' >&2
    exit 64
fi
profile="$1"; apk_source="$2"; serial="$3"
[[ "$profile" =~ ^(app7|app9|app11|app303-get-my-audio-android)$ ]] || { echo "not an Android profile: $profile" >&2; exit 64; }
[[ -n "$serial" && "$serial" != *[[:space:]]* ]] || { echo 'select a device serial with adb devices -l' >&2; exit 64; }
adb devices -l
state="$(adb -s "$serial" get-state 2>/dev/null || true)"
[[ "$state" == device ]] || { echo "device $serial is not ready (state: ${state:-missing})" >&2; exit 1; }
if [[ "$apk_source" == https://* ]]; then
    out="${TCX_USER_RUNS_DIR:-$HOME/runs}/$profile-user-apks"
    mkdir -p "$out"
    apk="$out/$(date -u +%Y%m%dT%H%M%SZ).apk"
    curl --fail --location --output "$apk" -- "$apk_source"
else
    apk="$(realpath "$apk_source")"
fi
[[ -s "$apk" ]] || { echo "APK missing or empty: $apk" >&2; exit 1; }
sha256sum "$apk"
package=''
if command -v aapt >/dev/null; then
    package="$(aapt dump badging "$apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
elif command -v apkanalyzer >/dev/null; then
    package="$(apkanalyzer manifest application-id "$apk")"
fi
adb -s "$serial" install -r "$apk"
if [[ -n "$package" ]]; then
    adb -s "$serial" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1
    printf 'installed and launched %s on %s from %s\n' "$package" "$serial" "$apk"
else
    printf 'installed on %s from %s; aapt or apkanalyzer is needed to discover and launch its package\n' "$serial" "$apk"
    exit 2
fi
