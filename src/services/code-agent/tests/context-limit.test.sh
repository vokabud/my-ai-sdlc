#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/context-limit.sh
source "$SERVICE_DIR/lib/context-limit.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" == "$expected" ]] \
        || fail_test "$message (expected '$expected', got '$actual')"
}

validate_model_context_limit ""
validate_model_context_limit "65536"

if validate_model_context_limit "0"; then
    fail_test "zero context limit must be rejected"
fi

if validate_model_context_limit "64k"; then
    fail_test "non-integer context limit must be rejected"
fi

assert_equals "null" "$(context_limit_json_value "")" \
    "an omitted context limit must be represented as JSON null"
assert_equals "65536" "$(context_limit_json_value "65536")" \
    "a configured context limit must remain a JSON number"

assert_equals "" "$(context_limit_prompt_instruction "")" \
    "an omitted context limit must not add prompt guidance"

context_instruction="$(context_limit_prompt_instruction "65536")"
[[ "$context_instruction" == *"65,536 tokens"* ]] \
    || fail_test "prompt guidance must expose the configured limit readably"
[[ "$context_instruction" == *"implementation and verification"* ]] \
    || fail_test "prompt guidance must reserve context for task completion"

cat > "$TEST_ROOT/template.json" <<'JSON'
{
  "provider": {
    "ollama": {
      "models": {
        "qwen": {
          "name": "Qwen",
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    }
  }
}
JSON

prepare_opencode_config \
    "$TEST_ROOT/template.json" \
    "$TEST_ROOT/configured.json" \
    "ollama/qwen" \
    "65536"

assert_equals "65536" \
    "$(jq -r '.provider.ollama.models.qwen.limit.context' "$TEST_ROOT/configured.json")" \
    "the configured limit must override the selected model context"
assert_equals "8192" \
    "$(jq -r '.provider.ollama.models.qwen.limit.output' "$TEST_ROOT/configured.json")" \
    "the context override must preserve existing model configuration"

prepare_opencode_config \
    "$TEST_ROOT/template.json" \
    "$TEST_ROOT/default.json" \
    "ollama/qwen" \
    ""

assert_equals "32768" \
    "$(jq -r '.provider.ollama.models.qwen.limit.context' "$TEST_ROOT/default.json")" \
    "an omitted limit must preserve the template context"

prepare_opencode_config \
    "$TEST_ROOT/template.json" \
    "$TEST_ROOT/unknown-model.json" \
    "openai/gpt-test" \
    "65536"

assert_equals "false" \
    "$(jq -r '.provider.openai.models["gpt-test"] != null' "$TEST_ROOT/unknown-model.json")" \
    "a context limit must not create an incomplete OpenCode model definition"

printf 'PASS: context-limit tests\n'
