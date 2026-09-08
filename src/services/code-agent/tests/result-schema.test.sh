#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
VALIDATION_STDERR="$TEST_ROOT/valid-validation.stderr"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/success.json" <<'JSON'
{
  "schemaVersion": 1,
  "status": "success",
  "task": {"id":"AIEXEC-123","repository":"owner/repository","baseBranch":"main"},
  "execution": {"model":"openai/test-model","contextLimitTokens":65536},
  "delivery": {"branch":"ai/AIEXEC-123","commit":"abc123","pullRequest":"https://github.com/owner/repository/pull/1"},
  "metrics": {"durationMs":42,"peakContextTokens":30,"inputTokens":20,"outputTokens":10,"llmRequests":1},
  "error": null
}
JSON

validate() {
  (
    cd "$SERVICE_DIR"
    npm exec -- ajv validate \
      --spec=draft2020 \
      -s result.schema.json \
      -d "$1" >/dev/null
  )
}

validate "$TEST_ROOT/success.json" 2> "$VALIDATION_STDERR"

jq '.status="failed" | .delivery.pullRequest=null | .error={stage:"pull-request",message:"Failed to create pull request"}' \
  "$TEST_ROOT/success.json" > "$TEST_ROOT/failure.json"
validate "$TEST_ROOT/failure.json" 2>> "$VALIDATION_STDERR"

if [[ -s "$VALIDATION_STDERR" ]]; then
  printf 'FAIL: valid schema fixtures produced validation warnings\n' >&2
  cat "$VALIDATION_STDERR" >&2
  exit 1
fi

jq 'del(.metrics)' "$TEST_ROOT/success.json" > "$TEST_ROOT/missing-field.json"
if validate "$TEST_ROOT/missing-field.json" 2>/dev/null; then
  printf 'FAIL: schema accepted a missing required section\n' >&2
  exit 1
fi

jq '.status="failed" | .error={stage:"ollama",message:"unsafe stage"}' \
  "$TEST_ROOT/success.json" > "$TEST_ROOT/invalid-stage.json"
if validate "$TEST_ROOT/invalid-stage.json" 2>/dev/null; then
  printf 'FAIL: schema accepted an undocumented failure stage\n' >&2
  exit 1
fi

jq '.status="failed" | .delivery.branch="ai/AIEXEC-123" | .delivery.commit=null | .delivery.pullRequest=null | .error={stage:"push",message:"Git push failed"}' \
  "$TEST_ROOT/success.json" > "$TEST_ROOT/invalid-order.json"
if validate "$TEST_ROOT/invalid-order.json" 2>/dev/null; then
  printf 'FAIL: schema accepted a pushed branch without a commit\n' >&2
  exit 1
fi

printf 'PASS: result schema tests\n'
