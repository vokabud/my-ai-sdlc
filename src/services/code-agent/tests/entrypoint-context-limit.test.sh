#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULT_FILE="$(mktemp --suffix=.json)"
ERROR_FILE="$(mktemp)"
trap 'rm -f "$RESULT_FILE" "$ERROR_FILE"' EXIT

set +e
REPO="owner/repository" \
TASK_ID="context-limit-test" \
TASK="Test task" \
GH_TOKEN="test-token" \
MODEL="ollama/qwen3.8:27b-64k" \
OLLAMA_URL="http://127.0.0.1:1/v1" \
MODEL_CONTEXT_LIMIT="0" \
    "$SERVICE_DIR/entrypoint.sh" implement \
    > "$RESULT_FILE" \
    2> "$ERROR_FILE"
exit_code="$?"
set -e

[[ "$exit_code" -ne 0 ]] || {
    printf 'FAIL: invalid context limit must fail\n' >&2
    exit 1
}

jq -e '
    .schemaVersion == 1
    and .status == "failed"
    and .task == {id:"context-limit-test",repository:"owner/repository",baseBranch:"main"}
    and .execution == {model:"ollama/qwen3.8:27b-64k",contextLimitTokens:null}
    and .delivery == {branch:null,commit:null,pullRequest:null}
    and .metrics == {durationMs:null,peakContextTokens:null,inputTokens:null,outputTokens:null,llmRequests:null}
    and .error.stage == "configuration"
    and (.error.message | contains("MODEL_CONTEXT_LIMIT"))
' "$RESULT_FILE" >/dev/null || {
    printf 'FAIL: invalid context limit must return a configuration failure\n' >&2
    exit 1
}

python3 "$SCRIPT_DIR/validate-result-schema.py" \
    "$SERVICE_DIR/result.schema.json" \
    "$RESULT_FILE" || {
    printf 'FAIL: invalid context limit result must match result.schema.json\n' >&2
    exit 1
}

printf 'PASS: entrypoint context-limit tests\n'
