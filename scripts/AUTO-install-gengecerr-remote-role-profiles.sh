#!/usr/bin/env bash
# Add three separate Gen-GEC-ERR remote twins, then regenerate all remote i3
# launchers and local three-window tmux layouts. Does not launch any sessions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profiles="${TCX_COCKPIT_PROFILES_FILE:-$HOME/.config/tcx-cockpit/profiles.conf}"
dirs="${TCX_LOCAL_DIRS:-$HOME/.config/tcx-cockpit/local-dirs.tsv}"
remote_dir='~/p/research-sketches/automatic-generation-correction-errortagging-v2'
experiment_dir='/home/b/p/research-sketches/automatic-generation-correction-errortagging-v2'
paper_dir='/home/b/p/writings/gen-gec-err'
instructions='/home/b/p/all-my-tiny-projects/claude-rules/instructions'

[[ -f "$profiles" && -f "$dirs" ]] || { echo 'cockpit profile files are missing' >&2; exit 1; }
[[ -d "$experiment_dir" && -d "$paper_dir" ]] || { echo 'Gen-GEC-ERR local directories are missing' >&2; exit 1; }
[[ -d "$instructions" ]] || { echo "Claude rules instruction directory is missing: $instructions" >&2; exit 1; }
for source in "$HERE"/../config/claude-rules/instructions/*.md; do
    target="$instructions/$(basename "$source")"
    if [[ -e "$target" ]]; then
        cmp -s "$source" "$target" || { echo "instruction file differs: $target" >&2; exit 1; }
    else
        install -m 644 "$source" "$target"
    fi
done
for name in gengecerr-dev gengecerr-paper gengecerr-pipeline-running; do
    grep -q "^${name}:" "$profiles" || printf '%s:wsl-:gge-%s:%s\n' "$name" "${name#gengecerr-}" "$remote_dir" >> "$profiles"
    local_dir="$experiment_dir"
    [[ "$name" == gengecerr-paper ]] && local_dir="$paper_dir"
    awk -F '\t' -v p="$name" '$1==p{found=1} END{exit !found}' "$dirs" || printf '%s\t%s\n' "$name" "$local_dir" >> "$dirs"
done
"$HERE/AUTO-tcx-remote-pair-gen.sh"
