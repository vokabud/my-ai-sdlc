#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULT_FILE="$(mktemp)"
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
    .status == "failed"
    and .stage == "configuration"
    and (.error | contains("MODEL_CONTEXT_LIMIT"))
' "$RESULT_FILE" >/dev/null || {
    printf 'FAIL: invalid context limit must return a configuration failure\n' >&2
    exit 1
}

printf 'PASS: entrypoint context-limit tests\n'
