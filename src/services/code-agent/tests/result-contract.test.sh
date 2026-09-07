#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

validate() {
  (
    cd "$SERVICE_DIR"
    npm exec -- ajv validate \
      --spec=draft2020 \
      -s result.schema.json \
      -d "$1" >/dev/null
  )
}

failure_json="$({
  source "$SERVICE_DIR/lib/result.sh"
  result_init "" "owner/repository" "main" ""
  result_emit_failure "configuration" "Required environment variable 'TASK_ID' is missing"
})"
printf '%s\n' "$failure_json" > "$TEST_ROOT/failure.json"
jq -e '
  .schemaVersion == 1 and .status == "failed"
  and .task == {id:null,repository:"owner/repository",baseBranch:"main"}
  and .execution == {model:null,contextLimitTokens:null}
  and .delivery == {branch:null,commit:null,pullRequest:null}
  and .metrics == {durationMs:null,peakContextTokens:null,inputTokens:null,outputTokens:null,llmRequests:null}
  and .error.stage == "configuration"
' "$TEST_ROOT/failure.json" >/dev/null
validate "$TEST_ROOT/failure.json"

success_json="$({
  source "$SERVICE_DIR/lib/result.sh"
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_set_context_limit 65536
  result_set_metrics 42 30 20 10 1
  result_record_commit abc123
  result_record_push ai/AIEXEC-123
  result_record_pull_request https://github.com/owner/repository/pull/1
  result_emit_success
})"
printf '%s\n' "$success_json" > "$TEST_ROOT/success.json"
jq -e '
  .status == "success" and .error == null
  and .delivery == {branch:"ai/AIEXEC-123",commit:"abc123",pullRequest:"https://github.com/owner/repository/pull/1"}
  and .metrics.durationMs == 42
' "$TEST_ROOT/success.json" >/dev/null
validate "$TEST_ROOT/success.json"

commit_failure_json="$({
  source "$SERVICE_DIR/lib/result.sh"
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_record_commit abc123
  result_emit_failure "push" "Git push failed"
})"
printf '%s\n' "$commit_failure_json" > "$TEST_ROOT/commit-failure.json"
jq -e '.delivery == {branch:null,commit:"abc123",pullRequest:null}' \
  "$TEST_ROOT/commit-failure.json" >/dev/null
validate "$TEST_ROOT/commit-failure.json"

guarded_failure_json="$({
  source "$SERVICE_DIR/lib/result.sh"
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_emit_failure "ollama" "provider-specific stage"
})"
printf '%s\n' "$guarded_failure_json" > "$TEST_ROOT/guarded-failure.json"
jq -e '.error == {stage:"worker",message:"Unexpected worker failure"}' \
  "$TEST_ROOT/guarded-failure.json" >/dev/null
validate "$TEST_ROOT/guarded-failure.json"

zero_metrics_json="$({
  source "$SERVICE_DIR/lib/result.sh"
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_set_metrics 0 0 0 0 0
  result_emit_failure "implementation" "No usage recorded"
})"
printf '%s\n' "$zero_metrics_json" > "$TEST_ROOT/zero-metrics.json"
jq -e '.metrics == {durationMs:0,peakContextTokens:0,inputTokens:0,outputTokens:0,llmRequests:0}' \
  "$TEST_ROOT/zero-metrics.json" >/dev/null
validate "$TEST_ROOT/zero-metrics.json"

printf 'PASS: result contract tests\n'
