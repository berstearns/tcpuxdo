#!/usr/bin/env bash
# Called by wsl-rescue.sh on every watch pass. Updates credpipe, pulls the
# current encrypted credential blob, and verifies the installed Claude creds.
# Never prints a key or credential value and never generates a replacement key.
set -uo pipefail

SOURCE_URL="${CREDPIPE_REPO_URL:-https://github.com/berstearns/credpipe.git}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="${CREDPIPE_DIR:-}"
fail(){ echo "CREDPIPE_PROBLEM $*"; exit 1; }

missing=()
for tool in git curl openssl socat jq; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} )); then
    echo "credpipe: installing missing programs: ${missing[*]}"
    sudo -n apt-get update -qq >/dev/null 2>&1 \
        && sudo -n apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    missing=()
    for tool in git curl openssl socat jq; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) || fail "programs missing: ${missing[*]}"
fi

if [[ -z "$DIR" ]]; then
    for candidate in "$HOME/credpipe" "$HOME/p/credpipe-main" /opt/credpipe; do
        if [[ -f "$candidate/credpipe" && -f "$candidate/.env" ]]; then
            DIR="$candidate"; break
        fi
    done
fi
if [[ -z "$DIR" ]]; then
    while IFS= read -r script; do
        candidate="$(dirname "$script")"
        if [[ -f "$candidate/.env" && -d "$candidate/.git" ]]; then
            DIR="$candidate"; break
        fi
    done < <(find "$HOME" -maxdepth 6 -type f -name credpipe 2>/dev/null)
fi
if [[ -z "$DIR" ]]; then
    for candidate in "$HOME/credpipe" "$HOME/p/credpipe-main" /opt/credpipe; do
        if [[ -f "$candidate/credpipe" && -d "$candidate/.git" ]]; then
            DIR="$candidate"; break
        fi
    done
fi

# A root-owned /opt checkout cannot be updated by an ordinary WSL user. Keep
# its existing ignored config, and maintain a writable checkout in the home dir.
if [[ -n "$DIR" && ! -w "$DIR/.git" ]]; then
    prior_env="$DIR/.env"
    DIR="$HOME/credpipe"
    if [[ ! -f "$DIR/credpipe" ]]; then
        [[ ! -e "$DIR" ]] || fail "$DIR exists but is not a credpipe checkout"
        git clone -q "$SOURCE_URL" "$DIR" || fail "could not download credpipe from GitHub"
    fi
    if [[ -f "$prior_env" && ! -f "$DIR/.env" ]]; then
        install -m600 "$prior_env" "$DIR/.env" || fail "could not copy existing credpipe config"
    fi
fi
if [[ -z "$DIR" ]]; then
    DIR="$HOME/credpipe"
fi
if [[ ! -f "$DIR/credpipe" ]]; then
    [[ ! -e "$DIR" ]] || fail "$DIR exists but is not a credpipe checkout"
    git clone -q "$SOURCE_URL" "$DIR" || fail "could not download credpipe from GitHub"
fi
[[ -f "$DIR/credpipe" && -d "$DIR/.git" ]] || fail "no valid credpipe checkout at $DIR"
echo "credpipe checkout: $DIR"

git -C "$DIR" remote set-url origin "$SOURCE_URL" 2>/dev/null \
    || git -C "$DIR" remote add origin "$SOURCE_URL" \
    || fail "could not configure credpipe GitHub source"
old_sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null)"
if [[ -n "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    git -C "$DIR" stash push -q -m "wsl-credpipe-rescue-$STAMP" \
        || fail "could not save local credpipe edits"
    echo "credpipe local edits saved in git stash"
fi
git -C "$DIR" fetch -q origin master || fail "could not update credpipe from GitHub"
git -C "$DIR" checkout -q master 2>/dev/null \
    || git -C "$DIR" checkout -q -b master origin/master \
    || fail "could not select credpipe master"
if ! git -C "$DIR" merge-base --is-ancestor HEAD origin/master; then
    saved="wsl-credpipe-saved-$STAMP"
    git -C "$DIR" branch "$saved" HEAD || fail "could not save diverged credpipe commits"
    echo "credpipe local commits preserved on branch $saved"
fi
git -C "$DIR" reset -q --hard origin/master || fail "could not update credpipe checkout"
new_sha="$(git -C "$DIR" rev-parse HEAD)"
[[ "$old_sha" == "$new_sha" ]] || echo "CREDPIPE_CODE_CHANGED $(git -C "$DIR" rev-parse --short HEAD)"

ENV_FILE="${CREDPIPE_ENV_FILE:-$DIR/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
    [[ "$ENV_FILE" == "$DIR/.env" ]] || fail "configured credpipe .env is missing"
    [[ -n "${TCPUX_RELAY_HOST:-}" ]] || fail "credpipe config missing and tcpuxdo relay host unavailable"
    (umask 077; printf 'CREDPIPE_HOST=%s\n' "$TCPUX_RELAY_HOST" > "$ENV_FILE") \
        || fail "could not write credpipe relay config"
fi
# The local ignored config may choose nondefault key/credential paths. Source
# it without displaying any values; the credpipe CLI does the same.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
if [[ -z "${CREDPIPE_HOST:-}" ]]; then
    [[ -n "${TCPUX_RELAY_HOST:-}" ]] || fail "credpipe relay host missing"
    printf 'CREDPIPE_HOST=%s\n' "$TCPUX_RELAY_HOST" >> "$ENV_FILE" \
        || fail "could not add credpipe relay host"
fi
key_path="${CREDPIPE_KEY:-$HOME/.config/credpipe/key}"
creds_path="${CREDPIPE_CREDS:-$HOME/.claude/.credentials.json}"
[[ -s "$key_path" ]] || fail "shared key missing at $key_path; it must be copied from main once"

pull_output="$(CREDPIPE_ENV_FILE="$ENV_FILE" "$DIR/credpipe" pull 2>&1)"
pull_rc=$?
(( pull_rc == 0 )) || fail "credpipe pull exited $pull_rc"
grep -q '^pulled ' <<<"$pull_output" \
    || fail "credpipe did not fetch/decrypt fresh credentials; check relay allowlist, blob and shared key"
if [[ ! -s "$creds_path" ]] || ! jq -e 'type == "object"' "$creds_path" >/dev/null 2>&1; then
    fail "installed Claude credential file missing or invalid"
fi

# Interactive Claude needs this flag as well as the credential JSON. Preserve
# every other existing setting and never print the file.
onboard="$HOME/.claude.json"
if [[ -f "$onboard" ]]; then
    jq -e 'type == "object"' "$onboard" >/dev/null 2>&1 \
        || fail "Claude onboarding settings are not valid JSON"
    if ! jq -e '.hasCompletedOnboarding == true' "$onboard" >/dev/null 2>&1; then
        tmp="$(mktemp "$HOME/.claude.json.XXXXXX")" || fail "could not update Claude onboarding"
        if ! jq '.hasCompletedOnboarding = true' "$onboard" > "$tmp" \
            || ! install -m600 "$tmp" "$onboard"; then
            rm -f "$tmp"
            fail "could not update Claude onboarding"
        fi
        rm -f "$tmp"
    fi
else
    (umask 077; printf '{"hasCompletedOnboarding":true}\n' > "$onboard") \
        || fail "could not create Claude onboarding settings"
fi

echo "CREDPIPE_OK relay credential blob pulled and valid JSON installed; checkout $(git -C "$DIR" rev-parse --short HEAD)"
