#!/usr/bin/env bash
# Download the newest published Hetzner APK by default, install it on the
# single connected USB phone by default, and launch its package. Runs only
# when the user invokes it in the user or ui pane.
set -euo pipefail
if (( $# < 1 || $# > 3 )); then
    echo 'usage: AUTO-download-install-and-launch-user-apk.sh PROFILE [HETZNER_APK_OR_URL_OR_FILE] [DEVICE_SERIAL]' >&2
    exit 64
fi
profile="$1"; apk_source="${2:-}"; serial="${3:-}"
[[ "$profile" =~ ^(app7|app9|app11|app303-get-my-audio-android)$ ]] || { echo "not an Android profile: $profile" >&2; exit 64; }
artifact_app="$profile"
[[ "$profile" == app303-get-my-audio-android ]] && artifact_app=app303
adb devices -l
if [[ -z "$serial" ]]; then
    mapfile -t phones < <(adb devices -l | awk '$2=="device" && $1 !~ /^emulator-/ {print $1}')
    (( ${#phones[@]} == 1 )) || { echo "expected one USB phone, found ${#phones[@]}; pass DEVICE_SERIAL (including for an emulator)" >&2; exit 64; }
    serial="${phones[0]}"
fi
[[ "$serial" != *[[:space:]]* ]] || { echo 'invalid device serial' >&2; exit 64; }
state="$(adb -s "$serial" get-state 2>/dev/null || true)"
[[ "$state" == device ]] || { echo "device $serial is not ready (state: ${state:-missing})" >&2; exit 1; }
if [[ -z "$apk_source" ]]; then
    remote_dir="hetzner:apps/$artifact_app/release"
    command -v rclone >/dev/null || { echo 'rclone is required for the default Hetzner APK' >&2; exit 1; }
    command -v jq >/dev/null || { echo 'jq is required to select the newest Hetzner APK' >&2; exit 1; }
    apk_name="$(rclone lsjson --files-only "$remote_dir" | jq -r '[.[] | select(.Name | endswith(".apk"))] | sort_by(.ModTime) | last | .Name // empty')"
    [[ -n "$apk_name" ]] || { echo "no APK found at $remote_dir; pass an explicit APK path or URL" >&2; exit 1; }
    apk_source="$remote_dir/$apk_name"
fi
if [[ "$apk_source" == https://* || "$apk_source" == hetzner:* ]]; then
    out="${TCX_USER_RUNS_DIR:-$HOME/runs}/$profile-user-apks"
    mkdir -p "$out"
    apk="$out/$(date -u +%Y%m%dT%H%M%SZ)-${apk_source##*/}"
    if [[ "$apk_source" == hetzner:* ]]; then
        rclone copyto "$apk_source" "$apk"
    else
        curl --fail --location --output "$apk" -- "$apk_source"
    fi
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
