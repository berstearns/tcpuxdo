#!/usr/bin/env bash
# Install the remote-whatsapp-filters i3minator entry without launching a tmux
# session or touching the worker. Re-running with the same inputs is harmless.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
profile=whatsapp-filters
worker=do-app11
remote_dir='~/repos/whatsapp-filters/docs'
local_dir=/home/b/p/all-my-tiny-projects/weekend-ideas/17.5-create-smarter-whatsapp-filters-based-on-knowledge-about-my-contacts/docs
profiles_file="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
local_dirs_file="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
tmuxinator_dir="${TMUXINATOR_DIR:-$HOME/.config/tmuxinator}"
tmuxinator_file="$here/../config/tmuxinator/remote-$profile.yml"

while (( $# )); do
    case "$1" in
        --worker) worker="${2:?--worker needs a value}"; shift 2 ;;
        --remote-dir) remote_dir="${2:?--remote-dir needs a value}"; shift 2 ;;
        *) echo "usage: $(basename "$0") [--worker NAME] [--remote-dir PATH]" >&2; exit 64 ;;
    esac
done
[[ "$worker" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid worker name: $worker" >&2; exit 64; }
[[ "$remote_dir" =~ ^[A-Za-z0-9._~/+-]+$ ]] || { echo "invalid remote directory: $remote_dir" >&2; exit 64; }
[[ -d "$local_dir" ]] || { echo "local docs directory is missing: $local_dir" >&2; exit 1; }
[[ -f "$profiles_file" && -f "$local_dirs_file" ]] || { echo "tcpuxdo cockpit config files are missing" >&2; exit 1; }
[[ -r "$tmuxinator_file" && -d "$tmuxinator_dir" ]] || { echo "tmuxinator template or config directory is missing" >&2; exit 1; }

profile_line="$profile:$worker:$profile:$remote_dir"
local_line="${profile}"$'\t'"${local_dir}"
if grep -q "^$profile:" "$profiles_file"; then
    grep -Fxq "$profile_line" "$profiles_file" || { echo "conflicting $profile entry in $profiles_file" >&2; exit 1; }
else
    printf '%s\n' "$profile_line" >> "$profiles_file"
fi
if grep -q "^$profile"$'\t' "$local_dirs_file"; then
    grep -Fxq "$local_line" "$local_dirs_file" || { echo "conflicting $profile entry in $local_dirs_file" >&2; exit 1; }
else
    printf '%s\n' "$local_line" >> "$local_dirs_file"
fi

install -m 644 "$tmuxinator_file" "$tmuxinator_dir/remote-$profile.yml"
"$here/AUTO-tcx-remote-pair-gen.sh" "$profile"
echo "installed remote-$profile i3minator and three-window tmuxinator twin for $worker:$remote_dir (local $local_dir); no session launched"
