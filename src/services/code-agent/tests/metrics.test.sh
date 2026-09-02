#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/metrics.sh
source "$SERVICE_DIR/lib/metrics.sh"

FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT

cat > "$FIXTURE" <<'JSON'
{
  "messages": [
    {
      "parts": [
        {
          "type": "step_finish",
          "tokens": {
            "input": 100,
            "output": 20,
            "cache": { "read": 30, "write": 5 }
          }
        },
        {
          "type": "step-finish",
          "tokens": {
            "input": 200,
            "output": 40,
            "cache": { "read": 50, "write": 10 }
          }
        }
      ]
    }
  ]
}
JSON

actual="$(extract_token_metrics "$FIXTURE")"
expected='{"peakContextTokens":260,"inputTokens":300,"outputTokens":60,"llmRequests":2}'

[[ "$actual" == "$expected" ]] || {
    printf 'FAIL: expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
}

printf 'PASS: metrics tests\n'
