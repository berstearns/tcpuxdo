#!/usr/bin/env bash
# Install one remote twin per app7, app9, app11, and app303. Config only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profiles="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
dirs="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
android_root='/home/b/p/minimal-android-apps'
worker="${ANDROID_REMOTE_WORKER:-wsl-}"

[[ -f "$profiles" && -f "$dirs" ]] || { echo 'cockpit profile files are missing' >&2; exit 1; }
[[ "$worker" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid worker name: $worker" >&2; exit 64; }
for path in "$android_root/app7-unified-master_20260804_110109" "$android_root/app9-latest" \
            "$android_root/app11-research-reader-rust-domain-fence_20260714_210906" \
            "$android_root/app303-get-my-audio-android"; do
    [[ -d "$path" ]] || { echo "missing local Android project: $path" >&2; exit 1; }
done

# Preserve the existing app7 and app11 worker/session bindings. The old app7
# local path is a dangling symlink; use the documented unified development repo.
tmp="$(mktemp "${dirs}.XXXXXX")"
awk -F '\t' -v p=app7 -v d="$android_root/app7-unified-master_20260804_110109" \
    'BEGIN{OFS="\t"} $1==p{$2=d} {print}' "$dirs" > "$tmp"
chmod --reference="$dirs" "$tmp"
mv "$tmp" "$dirs"

for spec in \
    "app9|app9|$android_root/app9-latest|~/p/minimal-android-apps/app9-latest" \
    "app303-get-my-audio-android|app303-get-my-audio-android|$android_root/app303-get-my-audio-android|~/p/minimal-android-apps/app303-get-my-audio-android"; do
    IFS='|' read -r name session local_dir remote_dir <<< "$spec"
    grep -q "^${name}:" "$profiles" || printf '%s:%s:%s:%s\n' "$name" "$worker" "$session" "$remote_dir" >> "$profiles"
    awk -F '\t' -v p="$name" '$1==p{found=1} END{exit !found}' "$dirs" || printf '%s\t%s\n' "$name" "$local_dir" >> "$dirs"
done
"$HERE/AUTO-tcx-remote-pair-gen.sh"
