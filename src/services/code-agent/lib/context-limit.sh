#!/usr/bin/env bash

validate_model_context_limit() {
    local value="$1"

    [[ -z "$value" ]] && return 0
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

context_limit_json_value() {
    local value="$1"

    if [[ -z "$value" ]]; then
        printf 'null\n'
    else
        printf '%s\n' "$value"
    fi
}

context_limit_prompt_instruction() {
    local value="$1"
    local digits
    local formatted=""

    [[ -z "$value" ]] && return 0

    digits="$value"
    while (( ${#digits} > 3 )); do
        formatted=",${digits: -3}${formatted}"
        digits="${digits:0:${#digits}-3}"
    done
    formatted="${digits}${formatted}"

    printf '%s\n' \
        "Your configured context-window limit is ${formatted} tokens. Manage repository exploration and tool output carefully, and preserve enough context for implementation and verification."
}

prepare_opencode_config() {
    local template_file="$1"
    local destination_file="$2"
    local model="$3"
    local context_limit="$4"
    local provider_id="${model%%/*}"
    local model_id="${model#*/}"

    if [[ -z "$context_limit" ]]; then
        cp "$template_file" "$destination_file"
        return
    fi

    jq \
        --arg provider "$provider_id" \
        --arg model "$model_id" \
        --argjson context "$context_limit" \
        'if (.provider[$provider].models[$model].limit.output? | type) == "number"
         then .provider[$provider].models[$model].limit.context = $context
         else .
         end' \
        "$template_file" \
        > "$destination_file"
}
