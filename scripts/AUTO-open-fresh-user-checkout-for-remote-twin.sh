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
source_root="$(git -C "$project" rev-parse --show-toplevel)"
project="$(realpath "$project")"
relative="${project#"$source_root"/}"
[[ "$project" == "$source_root" ]] && relative='.'
base="${TCX_USER_RUNS_DIR:-$HOME/runs}"
checkout="$base/$profile-user-checkout"
mkdir -p "$base"
exec 9>"$base/.$profile-user-checkout.lock"
flock 9
if [[ ! -d "$checkout/.git" ]]; then
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
[[ -d "$checkout/$relative" ]] || {
    echo "user checkout lacks profile subdirectory: $checkout/$relative" >&2
    exit 1
}
printf 'user checkout: %s at %s\n' "$checkout" "$(git -C "$checkout" rev-parse --short HEAD)" >&2
if [[ "$mode" == --shell ]]; then
    cd "$checkout/$relative"
    exec "${SHELL:-/bin/bash}"
fi
printf '%s\n' "$checkout/$relative"
