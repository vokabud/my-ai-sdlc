#!/usr/bin/env bash
set -Eeuo pipefail

WORK_ROOT="/work"
WORKSPACE="${WORK_ROOT}/repo"
CONFIG_FILE="${WORKSPACE}/opencode.json"
OPENCODE_EVENTS_FILE="/tmp/opencode-events.jsonl"
OPENCODE_SESSION_FILE="/tmp/opencode-session.json"
OPENCODE_STDERR_FILE="/tmp/opencode-stderr.log"
OPENCODE_SESSION_LIST_STDERR_FILE="/tmp/opencode-session-list-stderr.log"
OPENCODE_EXPORT_STDERR_FILE="/tmp/opencode-export-stderr.log"
PEAK_CONTEXT_TOKENS=null
INPUT_TOKENS=null
OUTPUT_TOKENS=null
LLM_REQUESTS=null

log() {
    echo "[sdlc-agent] $*" >&2
}

debug() {
    if [[ "$LOG_LEVEL" == "debug" ]]; then
        echo "[sdlc-agent] [debug] $*" >&2
    fi
}

now_ms() {
    if [[ -r /proc/uptime ]]; then
        awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
        return
    fi

    # The supported Linux container always provides /proc/uptime. This
    # wall-clock fallback exists only so disposable non-Linux harnesses can run.
    if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
        debug "Monotonic /proc/uptime unavailable; using non-Linux harness wall-clock fallback"
        date +%s%3N
        return
    fi

    return 1
}

diagnostic_counts() {
    local diagnostic_file="$1"
    local byte_count=0
    local line_count=0

    if [[ -f "$diagnostic_file" ]]; then
        byte_count="$(wc -c < "$diagnostic_file")"
        line_count="$(wc -l < "$diagnostic_file")"
    fi

    printf '%s %s\n' "$byte_count" "$line_count"
}

debug_opencode_command_failure() {
    local command_name="$1"
    local exit_code="$2"
    local stderr_file="$3"
    local stderr_bytes
    local stderr_lines

    read -r stderr_bytes stderr_lines < <(diagnostic_counts "$stderr_file")
    debug "$command_name failed: exitCode=$exit_code durationMs=$DURATION_MS stderrBytes=$stderr_bytes stderrLines=$stderr_lines stderrPath=$stderr_file"
}

debug_opencode_events() {
    [[ "$LOG_LEVEL" == "debug" ]] || return 0

    local event_metadata

    while IFS= read -r event_metadata; do
        debug "OpenCode event: $event_metadata"
    done < <(
        jq -rc '
            def string_or_null: if type == "string" then . else null end;
            {
                eventType: ((.type? // .event?.type? // .part?.type? // null) | string_or_null),
                toolName: (
                    .tool?.name?
                    // .part?.tool?.name?
                    // .part?.tool?
                    // null
                    | string_or_null
                ),
                finishReason: ((.finish_reason? // .finishReason? // .reason? // .part?.reason? // null) | string_or_null)
            }
            | with_entries(select(.value != null))
            | select(length > 0)
        ' "$OPENCODE_EVENTS_FILE" 2>/dev/null || true
    )
}

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

    metrics_json="$(
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
        ' "$OPENCODE_SESSION_FILE" 2>/dev/null
    )" || {
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

fail() {
    local stage="$1"
    local message="$2"

    # Avoid triggering ERR trap recursively while exiting through fail().
    trap - ERR

    jq -n \
        --arg status "failed" \
        --arg stage "$stage" \
        --arg message "$message" \
        --arg taskId "${TASK_ID:-unknown}" \
        '{
            status: $status,
            taskId: $taskId,
            stage: $stage,
            error: $message
        }'

    exit 1
}

require_env() {
    local name="$1"

    if [[ -z "${!name:-}" ]]; then
        fail "configuration" "Required environment variable '$name' is missing"
    fi
}

usage() {
    cat >&2 <<'EOF'
Usage:
  sdlc-agent implement

Required environment variables:
  REPO
  TASK_ID
  TASK
  GH_TOKEN
  MODEL

Provider-specific variables:

  Ollama:
    MODEL=ollama/qwen3.8:27b-64k
    OLLAMA_URL=http://host:11434/v1

  OpenAI:
    MODEL=openai/<model-name>
    OPENAI_API_KEY=<api-key>

Optional environment variables:
  LOG_LEVEL
      Default: info
      Supported: info, debug

  BASE_BRANCH
      Default: main

  BRANCH
      Default: ai/<TASK_ID>

  COMMIT_MESSAGE
      Default: AI implementation for <TASK_ID>

  PR_TITLE
      Default: AI implementation: <TASK_ID>
EOF
}

if [[ "${1:-}" != "implement" ]]; then
    usage
    exit 2
fi


# ------------------------------------------------------------
# Validate common configuration
# ------------------------------------------------------------

require_env REPO
require_env TASK_ID
require_env TASK
require_env GH_TOKEN
require_env MODEL

LOG_LEVEL="${LOG_LEVEL:-info}"

if [[ "$LOG_LEVEL" != "info" && "$LOG_LEVEL" != "debug" ]]; then
    fail "configuration" "Unsupported LOG_LEVEL='$LOG_LEVEL'. Expected info or debug"
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH="${BRANCH:-ai/${TASK_ID}}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-AI implementation for ${TASK_ID}}"
PR_TITLE="${PR_TITLE:-AI implementation: ${TASK_ID}}"


# ------------------------------------------------------------
# Validate provider-specific configuration
# ------------------------------------------------------------

if [[ "$MODEL" == ollama/* ]]; then
    require_env OLLAMA_URL
elif [[ "$MODEL" == openai/* ]]; then
    require_env OPENAI_API_KEY
else
    fail \
        "configuration" \
        "Unsupported model provider in MODEL='$MODEL'. Expected ollama/... or openai/..."
fi


# ------------------------------------------------------------
# Global error handler
# ------------------------------------------------------------

trap 'fail "worker" "Unexpected worker failure"' ERR


# ------------------------------------------------------------
# Log worker configuration
# ------------------------------------------------------------

log "Task:       $TASK_ID"
log "Repository: $REPO"
log "Base:       $BASE_BRANCH"
log "Branch:     $BRANCH"
log "Model:      $MODEL"


# ------------------------------------------------------------
# Check model provider
# ------------------------------------------------------------

if [[ "$MODEL" == ollama/* ]]; then
    log "Checking Ollama at $OLLAMA_URL"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        "${OLLAMA_URL%/}/models" \
        >/dev/null \
        || fail "ollama" "Cannot reach Ollama at $OLLAMA_URL"

    log "Ollama is reachable"
fi


# ------------------------------------------------------------
# Check GitHub authentication
# ------------------------------------------------------------

log "Checking GitHub authentication"

export GH_TOKEN

gh auth status >/dev/null 2>&1 \
    || fail "github-auth" "GH_TOKEN authentication failed"

gh auth setup-git \
    >&2 \
    || fail "github-auth" "Failed to configure Git credentials"

log "GitHub authentication OK"


# ------------------------------------------------------------
# Prepare workspace
# ------------------------------------------------------------

log "Preparing workspace"

rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"


# ------------------------------------------------------------
# Clone repository
# ------------------------------------------------------------

log "Cloning $REPO"

gh repo clone "$REPO" "$WORKSPACE" \
    >&2 \
    || fail "clone" "Repository clone failed"

cd "$WORKSPACE"


# ------------------------------------------------------------
# Checkout latest base branch
# ------------------------------------------------------------

log "Checking out base branch '$BASE_BRANCH'"

git fetch origin "$BASE_BRANCH" \
    >&2 \
    || fail "git" "Failed to fetch base branch '$BASE_BRANCH'"

git checkout "$BASE_BRANCH" \
    >&2 \
    || fail "git" "Failed to checkout base branch '$BASE_BRANCH'"

git reset --hard "origin/$BASE_BRANCH" \
    >&2 \
    || fail "git" "Failed to reset to origin/$BASE_BRANCH"


# ------------------------------------------------------------
# Make sure target branch does not already exist
# ------------------------------------------------------------

if git ls-remote \
    --exit-code \
    --heads \
    origin \
    "$BRANCH" \
    >/dev/null 2>&1
then
    fail "branch" "Remote branch '$BRANCH' already exists"
fi


# ------------------------------------------------------------
# Create implementation branch
# ------------------------------------------------------------

log "Creating branch '$BRANCH'"

git checkout -b "$BRANCH" \
    >&2 \
    || fail "branch" "Failed to create branch '$BRANCH'"


# ------------------------------------------------------------
# Prepare OpenCode configuration
# ------------------------------------------------------------

log "Preparing OpenCode configuration"

cp \
    /opt/sdlc/opencode.json.template \
    "$CONFIG_FILE" \
    >&2 \
    || fail "configuration" "Failed to create OpenCode configuration"

echo "/opencode.json" >> .git/info/exclude \
    || fail "configuration" "Failed to exclude OpenCode configuration from Git"


# ------------------------------------------------------------
# Run coding agent
# ------------------------------------------------------------

log "Starting OpenCode"
debug "OpenCode diagnostic paths: events=$OPENCODE_EVENTS_FILE stderr=$OPENCODE_STDERR_FILE session=$OPENCODE_SESSION_FILE sessionListStderr=$OPENCODE_SESSION_LIST_STDERR_FILE exportStderr=$OPENCODE_EXPORT_STDERR_FILE"

PROMPT="$TASK

You are running inside an isolated ephemeral coding worker.

Rules:
- Work only inside the current repository.
- Inspect the existing implementation before changing files.
- Implement only the requested task.
- Follow existing project conventions.
- Run relevant restore/build/test/lint commands.
- Fix failures introduced by your changes.
- Do not commit.
- Do not push.
- Do not create or modify pull requests.
- Do not install operating-system packages.
- Finish with a concise implementation and verification summary."

# The OpenCode exit code is handled explicitly below. Disable the global ERR
# trap here so a non-zero agent exit is reported as an implementation failure.
trap - ERR
set +e

AGENT_STARTED_MS="$(now_ms)"

env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    opencode run \
        --auto \
        --format json \
        --model "$MODEL" \
        "$PROMPT" \
    2> "$OPENCODE_STDERR_FILE" \
    | tee "$OPENCODE_EVENTS_FILE" >/dev/null

AGENT_EXIT="${PIPESTATUS[0]}"
AGENT_FINISHED_MS="$(now_ms)"

set -e
trap 'fail "worker" "Unexpected worker failure"' ERR

if [[ ! "$AGENT_STARTED_MS" =~ ^[0-9]+$ \
    || ! "$AGENT_FINISHED_MS" =~ ^[0-9]+$ \
    || "$AGENT_FINISHED_MS" -lt "$AGENT_STARTED_MS" ]]; then
    fail "worker" "Invalid OpenCode duration measurement"
fi

DURATION_MS="$((AGENT_FINISHED_MS - AGENT_STARTED_MS))"

if [[ ! "$DURATION_MS" =~ ^[0-9]+$ ]]; then
    fail "worker" "Invalid OpenCode duration '$DURATION_MS'"
fi

debug_opencode_events


# ------------------------------------------------------------
# Check OpenCode result
# ------------------------------------------------------------

if [[ "$AGENT_EXIT" -ne 0 ]]; then
    read -r OPENCODE_STDERR_BYTES OPENCODE_STDERR_LINES \
        < <(diagnostic_counts "$OPENCODE_STDERR_FILE")
    log "OpenCode failed: exit code $AGENT_EXIT durationMs=$DURATION_MS stderrBytes=$OPENCODE_STDERR_BYTES stderrLines=$OPENCODE_STDERR_LINES"
    debug "OpenCode stderr path: $OPENCODE_STDERR_FILE"
    fail \
        "implementation" \
        "OpenCode exited with code $AGENT_EXIT"
fi

log "OpenCode completed successfully"
collect_opencode_metrics


# ------------------------------------------------------------
# Verify that the agent actually changed something
# ------------------------------------------------------------

if git diff --quiet && git diff --cached --quiet; then
    fail \
        "implementation" \
        "Agent completed successfully but repository has no changes"
fi


# ------------------------------------------------------------
# Show resulting changes
# ------------------------------------------------------------

log "Repository changes:"

git status --short >&2

log "Diff statistics:"

git diff --stat >&2


# ------------------------------------------------------------
# Commit changes
# ------------------------------------------------------------

log "Creating commit"

git config user.name "SDLC Coding Agent" >&2
git config user.email "sdlc-agent@users.noreply.github.com" >&2

git add --all >&2

git commit -m "$COMMIT_MESSAGE" \
    >&2 \
    || fail "commit" "Git commit failed"

COMMIT_SHA="$(git rev-parse HEAD)"

log "Created commit $COMMIT_SHA"


# ------------------------------------------------------------
# Push branch
# ------------------------------------------------------------

log "Pushing branch '$BRANCH'"

git push \
    --set-upstream \
    origin \
    "$BRANCH" \
    >&2 \
    || fail "push" "Git push failed"


# ------------------------------------------------------------
# Build pull request body
# ------------------------------------------------------------

PR_BODY="$(cat <<EOF
Automated implementation for task \`${TASK_ID}\`.

### Worker

- Model: \`${MODEL}\`
- Base branch: \`${BASE_BRANCH}\`
- Branch: \`${BRANCH}\`
- Commit: \`${COMMIT_SHA}\`

### Execution summary

- OpenCode completed successfully.
- Duration: \`${DURATION_MS} ms\`
- Peak context tokens: \`$(metric_value_or_unavailable "$PEAK_CONTEXT_TOKENS")\`
- Input tokens: \`$(metric_value_or_unavailable "$INPUT_TOKENS")\`
- Output tokens: \`$(metric_value_or_unavailable "$OUTPUT_TOKENS")\`
- LLM requests: \`$(metric_value_or_unavailable "$LLM_REQUESTS")\`
EOF
)"


# ------------------------------------------------------------
# Create pull request
# ------------------------------------------------------------

log "Creating pull request"

PR_URL="$(
    gh pr create \
        --repo "$REPO" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "$PR_TITLE" \
        --body "$PR_BODY"
)" || fail "pull-request" "Failed to create pull request"

log "Pull request created: $PR_URL"


# ------------------------------------------------------------
# Return machine-readable result
# ------------------------------------------------------------

METRICS_JSON="$(jq -n \
    --argjson durationMs "$DURATION_MS" \
    --argjson peakContextTokens "${PEAK_CONTEXT_TOKENS:-null}" \
    --argjson inputTokens "${INPUT_TOKENS:-null}" \
    --argjson outputTokens "${OUTPUT_TOKENS:-null}" \
    --argjson llmRequests "${LLM_REQUESTS:-null}" \
    '{
        durationMs: $durationMs,
        peakContextTokens: $peakContextTokens,
        inputTokens: $inputTokens,
        outputTokens: $outputTokens,
        llmRequests: $llmRequests
    }'
)"

jq -n \
    --arg status "success" \
    --arg taskId "$TASK_ID" \
    --arg repo "$REPO" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT_SHA" \
    --arg pullRequest "$PR_URL" \
    --arg model "$MODEL" \
    --argjson metrics "$METRICS_JSON" \
    '{
        status: $status,
        taskId: $taskId,
        repository: $repo,
        branch: $branch,
        commit: $commit,
        pullRequest: $pullRequest,
        model: $model,
        metrics: $metrics
    }'
