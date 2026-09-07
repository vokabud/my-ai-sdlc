#!/usr/bin/env bash

result_init() {
  RESULT_TASK_ID="$1"
  RESULT_REPOSITORY="$2"
  RESULT_BASE_BRANCH="$3"
  RESULT_MODEL="$4"
  RESULT_CONTEXT_LIMIT_TOKENS=null
  RESULT_DURATION_MS=null
  RESULT_PEAK_CONTEXT_TOKENS=null
  RESULT_INPUT_TOKENS=null
  RESULT_OUTPUT_TOKENS=null
  RESULT_LLM_REQUESTS=null
  RESULT_BRANCH=""
  RESULT_COMMIT=""
  RESULT_PULL_REQUEST=""
}

result_set_context_limit() { RESULT_CONTEXT_LIMIT_TOKENS="$1"; }

result_set_metrics() {
  RESULT_DURATION_MS="$1"
  RESULT_PEAK_CONTEXT_TOKENS="$2"
  RESULT_INPUT_TOKENS="$3"
  RESULT_OUTPUT_TOKENS="$4"
  RESULT_LLM_REQUESTS="$5"
}

result_record_commit() {
  if [[ -z "$1" ]]; then
    return 1
  fi
  RESULT_COMMIT="$1"
}

result_record_push() {
  if [[ -z "$RESULT_COMMIT" || -z "$1" ]]; then
    return 1
  fi
  RESULT_BRANCH="$1"
}

result_record_pull_request() {
  if [[ -z "$RESULT_COMMIT" || -z "$RESULT_BRANCH" || -z "$1" ]]; then
    return 1
  fi
  RESULT_PULL_REQUEST="$1"
}

result_stage_is_valid() {
  case "$1" in
    configuration|provider-connectivity|github-authentication|clone|base-branch|implementation-branch|implementation|commit|push|pull-request|worker)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

result_sanitize_message() {
  printf '%s' "$1" | sed -E \
    -e 's/(token|api[_-]?key|secret|password|authorization|bearer)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/Ig' \
    -e 's/(sk|ghp|gho|github_pat)_[A-Za-z0-9_]+/[REDACTED]/g'
}

result_emit() {
  local status="$1"
  local stage="$2"
  local message="$3"

  jq -n \
    --arg status "$status" \
    --arg taskId "$RESULT_TASK_ID" \
    --arg repository "$RESULT_REPOSITORY" \
    --arg baseBranch "$RESULT_BASE_BRANCH" \
    --arg model "$RESULT_MODEL" \
    --arg branch "$RESULT_BRANCH" \
    --arg commit "$RESULT_COMMIT" \
    --arg pullRequest "$RESULT_PULL_REQUEST" \
    --arg stage "$stage" \
    --arg message "$message" \
    --argjson contextLimitTokens "$RESULT_CONTEXT_LIMIT_TOKENS" \
    --argjson durationMs "$RESULT_DURATION_MS" \
    --argjson peakContextTokens "$RESULT_PEAK_CONTEXT_TOKENS" \
    --argjson inputTokens "$RESULT_INPUT_TOKENS" \
    --argjson outputTokens "$RESULT_OUTPUT_TOKENS" \
    --argjson llmRequests "$RESULT_LLM_REQUESTS" \
    'def nullable: if length == 0 then null else . end;
     {
       schemaVersion: 1,
       status: $status,
       task: {
         id: ($taskId | nullable),
         repository: ($repository | nullable),
         baseBranch: ($baseBranch | nullable)
       },
       execution: {
         model: ($model | nullable),
         contextLimitTokens: $contextLimitTokens
       },
       delivery: {
         branch: ($branch | nullable),
         commit: ($commit | nullable),
         pullRequest: ($pullRequest | nullable)
       },
       metrics: {
         durationMs: $durationMs,
         peakContextTokens: $peakContextTokens,
         inputTokens: $inputTokens,
         outputTokens: $outputTokens,
         llmRequests: $llmRequests
       },
       error: if $status == "success" then null else {stage: $stage, message: $message} end
     }'
}

result_emit_success() {
  result_emit "success" "" ""
}

result_emit_failure() {
  local stage="$1"
  local message="$2"

  if ! result_stage_is_valid "$stage"; then
    stage="worker"
    message="Unexpected worker failure"
  else
    message="$(result_sanitize_message "$message")"
  fi

  result_emit "failed" "$stage" "$message"
}
