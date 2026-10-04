#!/usr/bin/env bash
# Shared, data-only agent choices for remote tmux twins. Source this file.

twin_options_path() {
    printf '%s/%s.conf\n' "${TCX_TWIN_OPTIONS_DIR:-$HOME/.config/tcx-cockpit/agent-options}" "$1"
}

twin_options_defaults() {
    TWIN_LOCAL_AGENT=codex
    TWIN_LOCAL_MODEL=gpt-6-sol
    TWIN_LOCAL_EFFORT=medium
    TWIN_REMOTE_AGENT=claude
    TWIN_REMOTE_MODEL=sonnet
    TWIN_REMOTE_EFFORT=medium
}

twin_options_load() {
    local profile="$1" path key value
    twin_options_defaults
    path="$(twin_options_path "$profile")"
    [[ -f "$path" ]] || return 0
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            local_agent) TWIN_LOCAL_AGENT="$value" ;;
            local_model) TWIN_LOCAL_MODEL="$value" ;;
            local_effort) TWIN_LOCAL_EFFORT="$value" ;;
            remote_agent) TWIN_REMOTE_AGENT="$value" ;;
            remote_model) TWIN_REMOTE_MODEL="$value" ;;
            remote_effort) TWIN_REMOTE_EFFORT="$value" ;;
            ''|'#'*) ;;
            *) printf 'unknown twin option %s in %s\n' "$key" "$path" >&2; return 1 ;;
        esac
    done < "$path"
    twin_options_validate
}

twin_options_validate() {
    local side agent model effort
    for side in LOCAL REMOTE; do
        if [[ "$side" == LOCAL ]]; then
            agent="$TWIN_LOCAL_AGENT"; model="$TWIN_LOCAL_MODEL"; effort="$TWIN_LOCAL_EFFORT"
        else
            agent="$TWIN_REMOTE_AGENT"; model="$TWIN_REMOTE_MODEL"; effort="$TWIN_REMOTE_EFFORT"
        fi
        [[ "$agent" == claude || "$agent" == codex ]] || { echo "invalid $side agent: $agent" >&2; return 64; }
        [[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || { echo "invalid $side model: $model" >&2; return 64; }
        if [[ "$agent" == claude ]]; then
            [[ "$effort" =~ ^(low|medium|high|xhigh|max)$ ]] || { echo "invalid Claude effort: $effort" >&2; return 64; }
        else
            [[ "$effort" =~ ^(low|medium|high|xhigh|max|ultra)$ ]] || { echo "invalid Codex effort: $effort" >&2; return 64; }
        fi
    done
}

twin_agent_defaults() { # agent; returns TWIN_DEFAULT_MODEL and TWIN_DEFAULT_EFFORT
    if [[ "$1" == codex ]]; then TWIN_DEFAULT_MODEL=gpt-6-sol
    else TWIN_DEFAULT_MODEL=sonnet; fi
    TWIN_DEFAULT_EFFORT=medium
}

twin_options_save() {
    local profile="$1" path dir tmp
    twin_options_validate || return $?
    path="$(twin_options_path "$profile")"
    dir="${path%/*}"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.${profile}.XXXXXX")" || return 1
    printf 'local_agent=%s\nlocal_model=%s\nlocal_effort=%s\nremote_agent=%s\nremote_model=%s\nremote_effort=%s\n' \
        "$TWIN_LOCAL_AGENT" "$TWIN_LOCAL_MODEL" "$TWIN_LOCAL_EFFORT" \
        "$TWIN_REMOTE_AGENT" "$TWIN_REMOTE_MODEL" "$TWIN_REMOTE_EFFORT" > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$path"
}

twin_agent_argv() { # agent model effort; returns command in TWIN_AGENT_ARGS
    local agent="$1" model="$2" effort="$3"
    if [[ "$agent" == codex ]]; then
        TWIN_AGENT_ARGS=(codex --dangerously-bypass-approvals-and-sandbox --model "$model" -c "model_reasoning_effort=$effort")
    else
        TWIN_AGENT_ARGS=(claude --dangerously-skip-permissions --model "$model" --effort "$effort")
    fi
}
