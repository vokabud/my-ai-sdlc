#!/usr/bin/env bash

metric_value_or_unavailable() {
    local value="$1"

    if [[ "$value" == "null" ]]; then
        printf '%s\n' "unavailable"
    else
        printf '%s\n' "$value"
    fi
}

reset_token_metrics() {
    PEAK_CONTEXT_TOKENS=null
    INPUT_TOKENS=null
    OUTPUT_TOKENS=null
    LLM_REQUESTS=null
}

log_token_metrics() {
    local valid_step_count="$1"
    local failure_reason="${2:-}"
    local peak_context_tokens
    local llm_requests
    local input_tokens
    local output_tokens

    peak_context_tokens="$(metric_value_or_unavailable "$PEAK_CONTEXT_TOKENS")"
    llm_requests="$(metric_value_or_unavailable "$LLM_REQUESTS")"
    input_tokens="$(metric_value_or_unavailable "$INPUT_TOKENS")"
    output_tokens="$(metric_value_or_unavailable "$OUTPUT_TOKENS")"

    log "OpenCode metrics: durationMs=$DURATION_MS peakContextTokens=$peak_context_tokens llmRequests=$llm_requests"
    debug "OpenCode metrics: inputTokens=$input_tokens outputTokens=$output_tokens validSteps=$valid_step_count"

    if [[ -n "$failure_reason" ]]; then
        debug "OpenCode metrics unavailable: $failure_reason"
    fi
}

discover_session_id_from_events() {
    local event_line
    local event_session_id

    [[ -r "$OPENCODE_EVENTS_FILE" ]] || return 1

    while IFS= read -r event_line || [[ -n "$event_line" ]]; do
        [[ -n "${event_line//[[:space:]]/}" ]] || continue

        event_session_id="$(
            printf '%s\n' "$event_line" \
                | jq -er '
                    if type == "object"
                        and (.sessionID? | type) == "string"
                        and (.sessionID | length) > 0
                    then .sessionID
                    else empty
                    end
                ' 2>/dev/null
        )" || continue

        printf '%s\n' "$event_session_id"
        return 0
    done < "$OPENCODE_EVENTS_FILE"

    return 1
}

discover_session_id_from_session_list() {
    local session_list
    local session_list_exit
    local session_id

    if session_list="$(
        env \
            -u GH_TOKEN \
            -u GITHUB_TOKEN \
            opencode session list --format json --max-count 1 \
            2> "$OPENCODE_SESSION_LIST_STDERR_FILE"
    )"; then
        :
    else
        session_list_exit="$?"
        debug_opencode_command_failure \
            "OpenCode session list" \
            "$session_list_exit" \
            "$OPENCODE_SESSION_LIST_STDERR_FILE"
        return 1
    fi

    session_id="$(
        printf '%s\n' "$session_list" \
            | jq -er '
                def session_id:
                    .id? // .sessionID? // .sessionId? // empty;

                if type == "array" then
                    .[0]?
                elif type == "object" then
                    if (.sessions? | type) == "array" then
                        .sessions[0]
                    elif (.data? | type) == "array" then
                        .data[0]
                    elif (.items? | type) == "array" then
                        .items[0]
                    else
                        .
                    end
                else
                    empty
                end
                | session_id
                | select(type == "string" and length > 0)
            ' 2>/dev/null
    )" || return 1

    [[ -n "$session_id" ]] || return 1

    printf '%s\n' "$session_id"
}

extract_token_metrics() {
    local session_file="$1"

    jq -sce '
        if length != 1 then
            error("session export must contain exactly one JSON value")
        else
            .[0]
            | [
                ..
                | objects
                | select(.type? == "step-finish" or .type? == "step_finish")
                | select(
                    (.tokens? | type) == "object"
                    and (.tokens.input? | type) == "number"
                    and (.tokens.output? | type) == "number"
                    and (.tokens.cache.read? | type) == "number"
                    and (.tokens.cache.write? | type) == "number"
                )
                | {
                    context: (.tokens.input + .tokens.cache.read + .tokens.cache.write),
                    input: .tokens.input,
                    output: .tokens.output
                }
            ] as $steps
            | if ($steps | length) == 0 then
                null
              else
                {
                    peakContextTokens: ($steps | map(.context) | max),
                    inputTokens: ($steps | map(.input) | add),
                    outputTokens: ($steps | map(.output) | add),
                    llmRequests: ($steps | length)
                }
              end
        end
    ' "$session_file" 2>/dev/null
}

collect_opencode_metrics() {
    local session_id=""
    local session_source=""
    local metrics_json
    local export_exit
    local parsed_metrics

    reset_token_metrics

    session_id="$(discover_session_id_from_events)" || true
    if [[ -n "$session_id" ]]; then
        session_source="events"
    else
        session_id="$(discover_session_id_from_session_list)" || true
        if [[ -n "$session_id" ]]; then
            session_source="session-list"
        fi
    fi

    if [[ -z "$session_id" ]]; then
        debug "OpenCode session ID unavailable"
        log_token_metrics "unavailable" "session ID unavailable"
        return 0
    fi

    debug "OpenCode session: sessionId=$session_id source=$session_source"

    if env \
        -u GH_TOKEN \
        -u GITHUB_TOKEN \
        opencode export "$session_id" \
        > "$OPENCODE_SESSION_FILE" \
        2> "$OPENCODE_EXPORT_STDERR_FILE"
    then
        :
    else
        export_exit="$?"
        debug_opencode_command_failure \
            "OpenCode session export" \
            "$export_exit" \
            "$OPENCODE_EXPORT_STDERR_FILE"
        log_token_metrics "unavailable" "session export failed"
        return 0
    fi

    if [[ ! -s "$OPENCODE_SESSION_FILE" ]]; then
        log_token_metrics "unavailable" "session export was empty"
        return 0
    fi

    if ! jq -e . "$OPENCODE_SESSION_FILE" >/dev/null 2>&1; then
        log_token_metrics "unavailable" "session export was invalid JSON"
        return 0
    fi

    metrics_json="$(extract_token_metrics "$OPENCODE_SESSION_FILE")" || {
        log_token_metrics "unavailable" "token metric extraction failed"
        return 0
    }

    if [[ "$metrics_json" == "null" ]]; then
        log_token_metrics "0" "no valid step usage records"
        return 0
    fi

    parsed_metrics="$(
        printf '%s\n' "$metrics_json" \
            | jq -er '
                [
                    .peakContextTokens,
                    .inputTokens,
                    .outputTokens,
                    .llmRequests
                ]
                | if all(.[]; type == "number") then
                    map(tostring) | join(" ")
                  else
                    error("metric values must be numeric")
                  end
            ' 2>/dev/null
    )" || {
        log_token_metrics "unavailable" "token metric values were invalid"
        return 0
    }

    read -r PEAK_CONTEXT_TOKENS INPUT_TOKENS OUTPUT_TOKENS LLM_REQUESTS <<< "$parsed_metrics"
    log_token_metrics "$LLM_REQUESTS"
}
