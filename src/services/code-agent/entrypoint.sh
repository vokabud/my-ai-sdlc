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

ENTRYPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$ENTRYPOINT_DIR/lib/context-limit.sh" ]]; then
    SDLC_LIB_DIR="$ENTRYPOINT_DIR/lib"
else
    SDLC_LIB_DIR="/opt/sdlc/lib"
fi

# shellcheck source=lib/context-limit.sh
source "$SDLC_LIB_DIR/context-limit.sh"
# shellcheck source=lib/metrics.sh
source "$SDLC_LIB_DIR/metrics.sh"
# shellcheck source=lib/result.sh
source "$SDLC_LIB_DIR/result.sh"
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

fail() {
    local stage="$1"
    local message="$2"
    trap - ERR
    result_emit_failure "$stage" "$message"
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
  MODEL_CONTEXT_LIMIT
      Positive integer context-window limit in tokens.

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

LOG_LEVEL="${LOG_LEVEL:-info}"
MODEL_CONTEXT_LIMIT="${MODEL_CONTEXT_LIMIT:-}"
BASE_BRANCH="${BASE_BRANCH:-main}"

result_init \
    "${TASK_ID:-}" \
    "${REPO:-}" \
    "$BASE_BRANCH" \
    "${MODEL:-}"

if [[ "${1:-}" != "implement" ]]; then
    usage
    fail "configuration" "Unsupported command; expected 'implement'"
fi


# ------------------------------------------------------------
# Validate common configuration
# ------------------------------------------------------------

require_env REPO
require_env TASK_ID
require_env TASK
require_env GH_TOKEN
require_env MODEL

if [[ "$LOG_LEVEL" != "info" && "$LOG_LEVEL" != "debug" ]]; then
    fail "configuration" "Unsupported LOG_LEVEL='$LOG_LEVEL'. Expected info or debug"
fi

if ! validate_model_context_limit "$MODEL_CONTEXT_LIMIT"; then
    fail \
        "configuration" \
        "MODEL_CONTEXT_LIMIT must be a positive integer when configured"
fi

if [[ -n "$MODEL_CONTEXT_LIMIT" ]]; then
    result_set_context_limit "$MODEL_CONTEXT_LIMIT"
fi

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
if [[ -n "$MODEL_CONTEXT_LIMIT" ]]; then
    log "Context:    $MODEL_CONTEXT_LIMIT tokens"
fi


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
        || fail "provider-connectivity" "Cannot reach Ollama at $OLLAMA_URL"

    log "Ollama is reachable"
fi


# ------------------------------------------------------------
# Check GitHub authentication
# ------------------------------------------------------------

log "Checking GitHub authentication"

export GH_TOKEN

gh auth status >/dev/null 2>&1 \
    || fail "github-authentication" "GH_TOKEN authentication failed"

gh auth setup-git \
    >&2 \
    || fail "github-authentication" "Failed to configure Git credentials"

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
    || fail "base-branch" "Failed to fetch base branch '$BASE_BRANCH'"

git checkout "$BASE_BRANCH" \
    >&2 \
    || fail "base-branch" "Failed to checkout base branch '$BASE_BRANCH'"

git reset --hard "origin/$BASE_BRANCH" \
    >&2 \
    || fail "base-branch" "Failed to reset to origin/$BASE_BRANCH"


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
    fail "implementation-branch" "Remote branch '$BRANCH' already exists"
fi


# ------------------------------------------------------------
# Create implementation branch
# ------------------------------------------------------------

log "Creating branch '$BRANCH'"

git checkout -b "$BRANCH" \
    >&2 \
    || fail "implementation-branch" "Failed to create branch '$BRANCH'"


# ------------------------------------------------------------
# Prepare OpenCode configuration
# ------------------------------------------------------------

log "Preparing OpenCode configuration"

prepare_opencode_config \
    /opt/sdlc/opencode.json.template \
    "$CONFIG_FILE" \
    "$MODEL" \
    "$MODEL_CONTEXT_LIMIT" \
    >&2 \
    || fail "configuration" "Failed to create OpenCode configuration"

echo "/opencode.json" >> .git/info/exclude \
    || fail "configuration" "Failed to exclude OpenCode configuration from Git"


# ------------------------------------------------------------
# Run coding agent
# ------------------------------------------------------------

log "Starting OpenCode"
debug "OpenCode diagnostic paths: events=$OPENCODE_EVENTS_FILE stderr=$OPENCODE_STDERR_FILE session=$OPENCODE_SESSION_FILE sessionListStderr=$OPENCODE_SESSION_LIST_STDERR_FILE exportStderr=$OPENCODE_EXPORT_STDERR_FILE"

CONTEXT_LIMIT_INSTRUCTION="$(context_limit_prompt_instruction "$MODEL_CONTEXT_LIMIT")"

PROMPT="$TASK

You are running inside an isolated ephemeral coding worker.

$CONTEXT_LIMIT_INSTRUCTION

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
collect_opencode_metrics
result_set_metrics \
    "$DURATION_MS" \
    "$PEAK_CONTEXT_TOKENS" \
    "$INPUT_TOKENS" \
    "$OUTPUT_TOKENS" \
    "$LLM_REQUESTS"


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
result_record_commit "$COMMIT_SHA"

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

result_record_push "$BRANCH"


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

result_record_pull_request "$PR_URL"

log "Pull request created: $PR_URL"


# ------------------------------------------------------------
# Return machine-readable result
# ------------------------------------------------------------

result_emit_success
