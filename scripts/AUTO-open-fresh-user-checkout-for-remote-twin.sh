#!/usr/bin/env bash
# Create a separate, committed-code checkout for the local user/tester window.
# Usage: AUTO-open-fresh-user-checkout-for-remote-twin.sh PROFILE [--path|--shell]
set -euo pipefail
profile="${1:-}"
mode="${2:---path}"
[[ "$profile" =~ ^[a-zA-Z0-9_-]+$ && ( "$mode" == --path || "$mode" == --shell ) ]] || {
    echo 'usage: AUTO-open-fresh-user-checkout-for-remote-twin.sh PROFILE [--path|--shell]' >&2
    exit 64
}
dirs="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
project="$(awk -F '\t' -v p="$profile" '$1==p {print $2; exit}' "$dirs")"
[[ -d "$project" ]] || { echo "user checkout: no local source for $profile: $project" >&2; exit 1; }
# app303's active application is its nested auto-app repository. The parent
# project path belongs to a different Git root with obsolete app303 files.
[[ "$profile" == app303-get-my-audio-android ]] && project="$project/auto-app"
# The LinkedIn keyboard twin develops a local-only TUI prototype. The user
# goal (feed/job annotations and Turso readback) lives in linkedin-scraping.
[[ "$profile" == linkedin ]] && project=/home/b/p/all-my-tiny-projects/linkedin-scraping
[[ -d "$project" ]] || { echo "user checkout: source missing: $project" >&2; exit 1; }
source_root="$(git -C "$project" rev-parse --show-toplevel)"
project="$(realpath "$project")"
relative="${project#"$source_root"/}"
[[ "$project" == "$source_root" ]] && relative='.'
base="${TCX_USER_RUNS_DIR:-$HOME/runs}"
checkout="$base/$profile-user-checkout"
[[ "$profile" == linkedin ]] && checkout="$base/linkedin-user-annotation-snapshot"
mkdir -p "$base"
exec 9>"$base/.$profile-user-checkout.lock"
flock 9
snapshot=0
if [[ "$profile" == linkedin ]] && ! git -C "$source_root" ls-files --error-unmatch "$relative/README.md" >/dev/null 2>&1; then
    snapshot=1
    if [[ ! -f "$checkout/.tcx-user-snapshot" ]]; then
        [[ ! -e "$checkout" ]] || { echo "user snapshot path exists but is not its snapshot: $checkout" >&2; exit 1; }
        partial="$base/.$profile-user-checkout.$$"
        cp -a -- "$project" "$partial"
        : > "$partial/.tcx-user-snapshot"
        mv -- "$partial" "$checkout"
    fi
elif [[ ! -d "$checkout/.git" ]]; then
    [[ ! -e "$checkout" ]] || { echo "user checkout path exists but is not a Git checkout: $checkout" >&2; exit 1; }
    partial="$base/.$profile-user-checkout.$$"
    remote=''
    for candidate in origin github; do
        url="$(git -C "$source_root" remote get-url "$candidate" 2>/dev/null || true)"
        if [[ "$url" == https://* || "$url" == git@* || "$url" == ssh://* ]]; then remote="$url"; break; fi
    done
    if [[ -n "$remote" ]]; then
        printf 'user checkout: cloning published remote into %s\n' "$checkout" >&2
        git clone -- "$remote" "$partial" >&2 || { rm -rf -- "$partial"; exit 1; }
    else
        printf 'user checkout: no published remote; cloning committed local Git history into %s\n' "$checkout" >&2
        git clone --no-local -- "$source_root" "$partial" >&2 || { rm -rf -- "$partial"; exit 1; }
    fi
    mv -- "$partial" "$checkout"
fi
flock -u 9
if (( snapshot )); then
    project_checkout="$checkout"
    printf 'user checkout: unpublished local snapshot at %s; no Git SHA or published source is available\n' "$checkout" >&2
else
    project_checkout="$checkout/$relative"
    printf 'user checkout: %s at %s\n' "$checkout" "$(git -C "$checkout" rev-parse --short HEAD)" >&2
fi
[[ -d "$project_checkout" ]] || {
    echo "user checkout lacks profile directory: $project_checkout" >&2
    exit 1
}
if [[ "$mode" == --shell ]]; then
    cd "$project_checkout"
    exec "${SHELL:-/bin/bash}"
fi
printf '%s\n' "$project_checkout"
