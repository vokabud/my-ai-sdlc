# Code-Agent Result Contract v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the worker's two unversioned result shapes with one schema-validated version 1 contract that truthfully reports known task data, execution metrics, delivery artifacts, and failures.

**Architecture:** A focused `lib/result.sh` module owns nullable result state and JSON rendering. `entrypoint.sh` initializes that state before validation, records artifacts only after their operations succeed, and routes all success and failure exits through the renderer. A Draft 2020-12 JSON Schema and shell tests define the public contract.

**Tech Stack:** Bash, jq, JSON Schema Draft 2020-12, Node.js 22, ajv-cli 5.0.0, Git, GitHub CLI, Podman

**Spec:** `docs/superpowers/specs/2026-09-07-code-agent-result-contract-design.md`

## Global Constraints

- Stdout contains exactly one final JSON document; operational logs remain on stderr.
- `schemaVersion` is the integer `1`; `status` is exactly `success` or `failed`.
- Every documented section and field is present; unknown or unavailable values are JSON `null`.
- Numeric zero means a measured zero and never means unavailable.
- `delivery.commit` is recorded only after commit, `delivery.branch` only after push, and `delivery.pullRequest` only after PR creation.
- `metrics` is present on success and failure; metric collection must not replace the primary failure.
- Error stages are the closed provider-independent set from the specification.
- Error output must not contain credentials, task prompts, captured stderr, model events, or repository file contents.
- Version 1 replaces the current flat output; no compatibility adapter is required because there are no existing consumers.
- Persistent Git artifacts and retryable delivery are roadmap work and are not implemented in this plan.

---

### Task 1: Define and validate the version 1 JSON Schema

**Files:**
- Create: `src/services/code-agent/result.schema.json`
- Create: `src/services/code-agent/package.json`
- Create: `src/services/code-agent/package-lock.json`
- Create: `src/services/code-agent/tests/result-schema.test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Contract field names, nullability, stage enum, and delivery ordering from the design spec.
- Produces: `result.schema.json`; test command `npm exec -- ajv validate --spec=draft2020 -s <schema> -d <document>`.

- [ ] **Step 1: Add the pinned schema-validator dependency**

Create `src/services/code-agent/package.json`:

```json
{
  "name": "sdlc-code-agent-contract-tests",
  "private": true,
  "devDependencies": {
    "ajv-cli": "5.0.0"
  }
}
```

Add this repository-root ignore rule to `.gitignore`:

```gitignore
# Node test dependencies
node_modules/
```

Generate the lock file without installing runtime dependencies:

```bash
cd src/services/code-agent
npm install --package-lock-only
```

Expected: `package-lock.json` pins `ajv-cli` and its transitive development dependencies.

- [ ] **Step 2: Write the schema test before the schema exists**

Create `tests/result-schema.test.sh`. The script creates a temporary valid success document and derives invalid documents with jq:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
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

validate "$TEST_ROOT/success.json"

jq '.status="failed" | .delivery.pullRequest=null | .error={stage:"pull-request",message:"Failed to create pull request"}' \
  "$TEST_ROOT/success.json" > "$TEST_ROOT/failure.json"
validate "$TEST_ROOT/failure.json"

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
```

- [ ] **Step 3: Run the schema test and verify the expected failure**

Run:

```bash
cd src/services/code-agent
npm ci
bash tests/result-schema.test.sh
```

Expected: FAIL because `result.schema.json` does not exist.

- [ ] **Step 4: Add the Draft 2020-12 schema**

Create `result.schema.json` with `additionalProperties: false` at every object boundary. Use these exact required fields and types:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://schemas.local/sdlc/code-agent-result-v1.json",
  "title": "SDLC Code Agent Result v1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "status", "task", "execution", "delivery", "metrics", "error"],
  "properties": {
    "schemaVersion": {"const": 1},
    "status": {"enum": ["success", "failed"]},
    "task": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "repository", "baseBranch"],
      "properties": {
        "id": {"type": ["string", "null"], "minLength": 1},
        "repository": {"type": ["string", "null"], "minLength": 1},
        "baseBranch": {"type": ["string", "null"], "minLength": 1}
      }
    },
    "execution": {
      "type": "object",
      "additionalProperties": false,
      "required": ["model", "contextLimitTokens"],
      "properties": {
        "model": {"type": ["string", "null"], "minLength": 1},
        "contextLimitTokens": {"type": ["integer", "null"], "minimum": 1}
      }
    },
    "delivery": {
      "type": "object",
      "additionalProperties": false,
      "required": ["branch", "commit", "pullRequest"],
      "properties": {
        "branch": {"type": ["string", "null"], "minLength": 1},
        "commit": {"type": ["string", "null"], "minLength": 1},
        "pullRequest": {"type": ["string", "null"], "minLength": 1}
      }
    },
    "metrics": {
      "type": "object",
      "additionalProperties": false,
      "required": ["durationMs", "peakContextTokens", "inputTokens", "outputTokens", "llmRequests"],
      "properties": {
        "durationMs": {"type": ["integer", "null"], "minimum": 0},
        "peakContextTokens": {"type": ["integer", "null"], "minimum": 0},
        "inputTokens": {"type": ["integer", "null"], "minimum": 0},
        "outputTokens": {"type": ["integer", "null"], "minimum": 0},
        "llmRequests": {"type": ["integer", "null"], "minimum": 0}
      }
    },
    "error": {
      "oneOf": [
        {"type": "null"},
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["stage", "message"],
          "properties": {
            "stage": {
              "enum": ["configuration", "provider-connectivity", "github-authentication", "clone", "base-branch", "implementation-branch", "implementation", "commit", "push", "pull-request", "worker"]
            },
            "message": {"type": "string", "minLength": 1}
          }
        }
      ]
    }
  },
  "allOf": [
    {
      "if": {"properties": {"status": {"const": "success"}}},
      "then": {
        "properties": {
          "task": {"properties": {"id":{"type":"string"},"repository":{"type":"string"},"baseBranch":{"type":"string"}}},
          "execution": {"properties": {"model":{"type":"string"}}},
          "delivery": {"properties": {"branch":{"type":"string"},"commit":{"type":"string"},"pullRequest":{"type":"string"}}},
          "metrics": {"properties": {"durationMs":{"type":"integer"}}},
          "error": {"type": "null"}
        }
      },
      "else": {"properties": {"error": {"type": "object"}}}
    },
    {
      "if": {"properties": {"delivery": {"properties": {"branch": {"type": "string"}}}}},
      "then": {"properties": {"delivery": {"properties": {"commit": {"type": "string"}}}}}
    },
    {
      "if": {"properties": {"delivery": {"properties": {"pullRequest": {"type": "string"}}}}},
      "then": {"properties": {"delivery": {"properties": {"branch": {"type": "string"}, "commit": {"type": "string"}}}}}
    }
  ]
}
```

- [ ] **Step 5: Run the schema test**

Run: `bash tests/result-schema.test.sh`

Expected: `PASS: result schema tests`.

- [ ] **Step 6: Commit the schema and validator**

```bash
git add .gitignore src/services/code-agent/package.json src/services/code-agent/package-lock.json src/services/code-agent/result.schema.json src/services/code-agent/tests/result-schema.test.sh
git commit -m "test: define code-agent result schema v1"
```

---

### Task 2: Build the stateful result renderer

**Files:**
- Create: `src/services/code-agent/lib/result.sh`
- Create: `src/services/code-agent/tests/result-contract.test.sh`

**Interfaces:**
- Consumes: jq and validated scalar values from the entrypoint.
- Produces: `result_init(task_id, repository, base_branch, model)`, `result_set_context_limit(tokens)`, `result_set_metrics(duration, peak, input, output, requests)`, `result_record_commit(sha)`, `result_record_push(branch)`, `result_record_pull_request(url)`, `result_emit_success()`, and `result_emit_failure(stage, message)`.

- [ ] **Step 1: Write renderer tests for nulls, success, failure, and transitions**

Create `tests/result-contract.test.sh`. Source `lib/result.sh`, then exercise a fresh failure and a completed success in separate subshells so global state does not leak:

```bash
failure_json="$({
  result_init "" "owner/repository" "main" ""
  result_emit_failure "configuration" "Required environment variable 'TASK_ID' is missing"
})"

jq -e '
  .schemaVersion == 1 and .status == "failed"
  and .task == {id:null,repository:"owner/repository",baseBranch:"main"}
  and .execution == {model:null,contextLimitTokens:null}
  and .delivery == {branch:null,commit:null,pullRequest:null}
  and .metrics == {durationMs:null,peakContextTokens:null,inputTokens:null,outputTokens:null,llmRequests:null}
  and .error.stage == "configuration"
' <<< "$failure_json" >/dev/null

success_json="$({
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_set_context_limit 65536
  result_set_metrics 42 30 20 10 1
  result_record_commit abc123
  result_record_push ai/AIEXEC-123
  result_record_pull_request https://github.com/owner/repository/pull/1
  result_emit_success
})"

jq -e '
  .status == "success" and .error == null
  and .delivery == {branch:"ai/AIEXEC-123",commit:"abc123",pullRequest:"https://github.com/owner/repository/pull/1"}
  and .metrics.durationMs == 42
' <<< "$success_json" >/dev/null
```

Add the transition and stage-guard assertions:

```bash
commit_failure_json="$({
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_record_commit abc123
  result_emit_failure "push" "Git push failed"
})"
jq -e '.delivery == {branch:null,commit:"abc123",pullRequest:null}' \
  <<< "$commit_failure_json" >/dev/null

guarded_failure_json="$({
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_emit_failure "ollama" "provider-specific stage"
})"
jq -e '.error == {stage:"worker",message:"Unexpected worker failure"}' \
  <<< "$guarded_failure_json" >/dev/null

zero_metrics_json="$({
  result_init "AIEXEC-123" "owner/repository" "main" "openai/test-model"
  result_set_metrics 0 0 0 0 0
  result_emit_failure "implementation" "No usage recorded"
})"
jq -e '.metrics == {durationMs:0,peakContextTokens:0,inputTokens:0,outputTokens:0,llmRequests:0}' \
  <<< "$zero_metrics_json" >/dev/null
```

Write each generated document to `$TEST_ROOT`, validate it with the Task 1 AJV command, and finish with `PASS: result contract tests`.

- [ ] **Step 2: Run the renderer test and verify the expected failure**

Run: `bash tests/result-contract.test.sh`

Expected: FAIL because `lib/result.sh` does not exist.

- [ ] **Step 3: Implement the renderer with initialized nullable state**

Create `lib/result.sh` with these state rules:

```bash
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

result_record_commit() { RESULT_COMMIT="$1"; }
result_record_push() { RESULT_BRANCH="$1"; }
result_record_pull_request() { RESULT_PULL_REQUEST="$1"; }
```

Add the renderer and stage guard:

```bash
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
  fi

  result_emit "failed" "$stage" "$message"
}
```

Do not call `exit` in this module; the entrypoint owns process status.

- [ ] **Step 4: Run renderer and schema tests**

Run:

```bash
bash tests/result-contract.test.sh
bash tests/result-schema.test.sh
```

Expected: both scripts print `PASS`.

- [ ] **Step 5: Commit the result module**

```bash
git add src/services/code-agent/lib/result.sh src/services/code-agent/tests/result-contract.test.sh
git commit -m "feat: add versioned result renderer"
```

---

### Task 3: Route entrypoint success and failure through the contract

**Files:**
- Modify: `src/services/code-agent/entrypoint.sh:4-25`
- Modify: `src/services/code-agent/entrypoint.sh:107-235`
- Modify: `src/services/code-agent/entrypoint.sh:256-355`
- Modify: `src/services/code-agent/entrypoint.sh:404-458`
- Modify: `src/services/code-agent/entrypoint.sh:485-602`
- Modify: `src/services/code-agent/tests/entrypoint-context-limit.test.sh`

**Interfaces:**
- Consumes: all `result_*` functions from Task 2 and the metric globals populated by `collect_opencode_metrics`.
- Produces: version 1 JSON for every expected exit from `entrypoint.sh implement`, including configuration failures.

- [ ] **Step 1: Update the existing entrypoint test to require the full failure contract**

Replace its flat-result jq assertion with:

```bash
jq -e '
  .schemaVersion == 1
  and .status == "failed"
  and .task == {id:"context-limit-test",repository:"owner/repository",baseBranch:"main"}
  and .execution == {model:"ollama/qwen3.8:27b-64k",contextLimitTokens:null}
  and .delivery == {branch:null,commit:null,pullRequest:null}
  and .metrics == {durationMs:null,peakContextTokens:null,inputTokens:null,outputTokens:null,llmRequests:null}
  and .error.stage == "configuration"
  and (.error.message | contains("MODEL_CONTEXT_LIMIT"))
' "$RESULT_FILE" >/dev/null
```

Validate `$RESULT_FILE` with the same AJV command used in `result-schema.test.sh`.

- [ ] **Step 2: Run the entrypoint test and verify the old shape fails**

Run: `bash tests/entrypoint-context-limit.test.sh`

Expected: FAIL because the entrypoint still emits top-level `stage` and a string `error`.

- [ ] **Step 3: Initialize result state before command and environment validation**

Source `lib/result.sh` beside the existing libraries. Move default calculation for `LOG_LEVEL`, `MODEL_CONTEXT_LIMIT`, and `BASE_BRANCH` before validation, then initialize:

```bash
LOG_LEVEL="${LOG_LEVEL:-info}"
MODEL_CONTEXT_LIMIT="${MODEL_CONTEXT_LIMIT:-}"
BASE_BRANCH="${BASE_BRANCH:-main}"

result_init \
  "${TASK_ID:-}" \
  "${REPO:-}" \
  "$BASE_BRANCH" \
  "${MODEL:-}"
```

After `validate_model_context_limit` succeeds, record a configured value only when non-empty:

```bash
if [[ -n "$MODEL_CONTEXT_LIMIT" ]]; then
  result_set_context_limit "$MODEL_CONTEXT_LIMIT"
fi
```

Change an unsupported command from a bare `exit 2` to `usage` followed by `fail "configuration" "Unsupported command; expected 'implement'"`, ensuring it also emits version 1 JSON.

- [ ] **Step 4: Replace both result emitters with the shared module**

Implement `fail` as:

```bash
fail() {
  local stage="$1"
  local message="$2"
  trap - ERR
  result_emit_failure "$stage" "$message"
  exit 1
}
```

Replace the final inline `METRICS_JSON` and success `jq` block with:

```bash
result_emit_success
```

- [ ] **Step 5: Normalize every failure stage**

Apply these exact mappings:

```text
ollama      -> provider-connectivity
github-auth -> github-authentication
git         -> base-branch
branch      -> implementation-branch
```

Keep `configuration`, `clone`, `implementation`, `commit`, `push`, `pull-request`, and `worker` unchanged. Do not include provider names in stage values.

- [ ] **Step 6: Record metrics and delivery artifacts only after success**

Move `collect_opencode_metrics` before the `AGENT_EXIT` failure check so failed OpenCode runs can still report token usage. Immediately afterward copy measured state into the result:

```bash
collect_opencode_metrics
result_set_metrics \
  "$DURATION_MS" \
  "$PEAK_CONTEXT_TOKENS" \
  "$INPUT_TOKENS" \
  "$OUTPUT_TOKENS" \
  "$LLM_REQUESTS"
```

After obtaining `COMMIT_SHA`, call `result_record_commit "$COMMIT_SHA"`. After `git push` succeeds, call `result_record_push "$BRANCH"`. After `gh pr create` succeeds, call `result_record_pull_request "$PR_URL"`.

- [ ] **Step 7: Run focused and existing tests**

Run:

```bash
bash -n entrypoint.sh lib/result.sh
bash tests/entrypoint-context-limit.test.sh
bash tests/result-contract.test.sh
bash tests/context-limit.test.sh
bash tests/metrics.test.sh
```

Expected: syntax validation exits zero and all four test scripts print `PASS`.

- [ ] **Step 8: Commit entrypoint integration**

```bash
git add src/services/code-agent/entrypoint.sh src/services/code-agent/tests/entrypoint-context-limit.test.sh
git commit -m "feat: emit result contract v1 from code-agent"
```

---

### Task 4: Verify failed OpenCode and delivery-stage artifact reporting

**Files:**
- Create: `src/services/code-agent/tests/entrypoint-lifecycle.test.sh`
- Modify: `src/services/code-agent/entrypoint.sh:4-10`

**Interfaces:**
- Consumes: version 1 entrypoint behavior from Task 3.
- Produces: deterministic integration coverage for implementation, commit, push, pull-request, and success outcomes without GitHub or model-provider access.

- [ ] **Step 1: Add a Linux command-mock integration harness**

Create `tests/entrypoint-lifecycle.test.sh`. It must:

Create a temporary bare Git origin and seed its `main` branch using the real Git binary before placing mocks on `PATH`:

```bash
/usr/bin/git init --bare "$TEST_ROOT/origin.git" >/dev/null
/usr/bin/git init "$TEST_ROOT/seed" >/dev/null
/usr/bin/git -C "$TEST_ROOT/seed" config user.name Test
/usr/bin/git -C "$TEST_ROOT/seed" config user.email test@example.invalid
printf 'initial\n' > "$TEST_ROOT/seed/README.md"
/usr/bin/git -C "$TEST_ROOT/seed" add README.md
/usr/bin/git -C "$TEST_ROOT/seed" commit -m initial >/dev/null
/usr/bin/git -C "$TEST_ROOT/seed" branch -M main
/usr/bin/git -C "$TEST_ROOT/seed" remote add origin "$TEST_ROOT/origin.git"
/usr/bin/git -C "$TEST_ROOT/seed" push -u origin main >/dev/null
TEST_ORIGIN="$TEST_ROOT/origin.git"
```

Create executable mocks under `$TEST_ROOT/mock-bin`. The `git` mock delegates all normal work:

```bash
#!/usr/bin/env bash
if [[ "${FAIL_STAGE:-}" == "commit" && "${1:-}" == "commit" ]]; then
  exit 1
fi
if [[ "${FAIL_STAGE:-}" == "push" && "${1:-}" == "push" ]]; then
  exit 1
fi
exec /usr/bin/git "$@"
```

The `gh` mock handles exactly the worker commands:

```bash
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status"|"auth setup-git")
    exit 0
    ;;
  "repo clone")
    exec /usr/bin/git clone "$TEST_ORIGIN" "$4"
    ;;
  "pr create")
    [[ "${FAIL_STAGE:-}" == "pull-request" ]] && exit 1
    printf '%s\n' "https://github.com/owner/repository/pull/1"
    ;;
  *)
    printf 'unexpected gh command: %s\n' "$*" >&2
    exit 2
    ;;
esac
```

The `opencode` mock produces a change, a discoverable session, and deterministic metrics:

```bash
#!/usr/bin/env bash
case "${1:-}" in
  run)
    printf 'implemented\n' > implemented.txt
    printf '%s\n' '{"sessionID":"test-session"}'
    [[ "${FAIL_STAGE:-}" == "implementation" ]] && exit 7
    ;;
  export)
    printf '%s\n' '{"messages":[{"parts":[{"type":"step_finish","tokens":{"input":20,"output":10,"cache":{"read":5,"write":1}}}]}]}'
    ;;
  *)
    printf 'unexpected opencode command: %s\n' "$*" >&2
    exit 2
    ;;
esac
```

Mark all three files executable. Each case uses a unique `TASK_ID` so a successful push from one case cannot make a later branch-existence check fail.

The test case runner invokes the worker with:

```bash
env \
  PATH="$MOCK_BIN:$PATH" \
  TEST_ORIGIN="$TEST_ORIGIN" \
  FAIL_STAGE="$failure_stage" \
  SDLC_WORK_ROOT="$TEST_ROOT/work-$case_name" \
  SDLC_OPENCODE_TEMPLATE="$SERVICE_DIR/opencode.json.template" \
  REPO="owner/repository" \
  TASK_ID="AIEXEC-123" \
  TASK="Create implemented.txt" \
  GH_TOKEN="test-token" \
  MODEL="openai/test-model" \
  OPENAI_API_KEY="test-key" \
  "$SERVICE_DIR/entrypoint.sh" implement \
  > "$result_file" 2> "$error_file"
```

Run four failure cases plus success and assert these exact artifact states:

```text
implementation: commit=null, branch=null, pullRequest=null, durationMs is a number
commit:         commit=null, branch=null, pullRequest=null
push:           commit is a string, branch=null, pullRequest=null
pull-request:   commit is a string, branch="ai/AIEXEC-pull-request", pullRequest=null
success:        commit is a string, branch="ai/AIEXEC-success", pullRequest is a URL
```

Implement the shared assertion with jq arguments rather than interpolating values into jq source:

```bash
jq -e \
  --arg status "$expected_status" \
  --arg stage "$expected_stage" \
  --arg branch "$expected_branch" '
    .schemaVersion == 1
    and .status == $status
    and (if $status == "success" then .error == null else .error.stage == $stage end)
    and (if $branch == "null" then .delivery.branch == null else .delivery.branch == $branch end)
    and (has("taskId") or has("repository") or has("branch") or has("commit") or has("pullRequest") or has("model") or has("contextLimitTokens") or has("stage") | not)
  ' "$result_file" >/dev/null
```

For every case, assert stdout contains exactly one JSON value with `jq -se 'length == 1'`, validates against `result.schema.json`, contains no old top-level fields (`taskId`, `repository`, `branch`, `commit`, `pullRequest`, `model`, `contextLimitTokens`, `stage`), and has an exit code matching `status`. Assert stderr is non-empty and does not contain `test-key`, `test-token`, or the task text.

- [ ] **Step 2: Run the lifecycle test and verify the test seams are missing**

Run: `bash tests/entrypoint-lifecycle.test.sh`

Expected: FAIL because the entrypoint still hard-codes `/work` and `/opt/sdlc/opencode.json.template`.

- [ ] **Step 3: Add narrow environment overrides for the integration harness**

At the top of `entrypoint.sh`, replace the two hard-coded values with defaults:

```bash
WORK_ROOT="${SDLC_WORK_ROOT:-/work}"
WORKSPACE="${WORK_ROOT}/repo"
OPENCODE_TEMPLATE="${SDLC_OPENCODE_TEMPLATE:-/opt/sdlc/opencode.json.template}"
```

Pass `$OPENCODE_TEMPLATE` to `prepare_opencode_config`. These are internal test seams; do not document them as public worker configuration.

- [ ] **Step 4: Run lifecycle and regression tests**

Run:

```bash
bash tests/entrypoint-lifecycle.test.sh
bash tests/entrypoint-context-limit.test.sh
bash tests/result-contract.test.sh
bash tests/result-schema.test.sh
bash tests/context-limit.test.sh
bash tests/metrics.test.sh
```

Expected: all six scripts print `PASS`.

- [ ] **Step 5: Commit lifecycle coverage**

```bash
git add src/services/code-agent/entrypoint.sh src/services/code-agent/tests/entrypoint-lifecycle.test.sh
git commit -m "test: cover code-agent delivery result states"
```

---

### Task 5: Document the contract, update the roadmap, and verify the image

**Files:**
- Modify: `src/services/code-agent/README.md:404-469`
- Modify: `ROADMAP.md:5-40`
- Modify: `ROADMAP.md:42-70`

**Interfaces:**
- Consumes: final schema and tested worker behavior from Tasks 1-4.
- Produces: operator documentation and a roadmap entry for durable, retryable delivery.

- [ ] **Step 1: Replace README success and failure examples with version 1 documents**

Use the examples from the design spec. Document each section in this order: `task`, `execution`, `delivery`, `metrics`, `error`. State explicitly:

```text
All sections and fields are always present. null means unknown, unavailable, or not yet created; zero is a measured value. delivery.commit proves local commit success, delivery.branch proves push success, and delivery.pullRequest proves pull-request creation.
```

List the exact stage enum and explain that `metrics.durationMs` covers OpenCode execution rather than the full container lifetime. Remove the old flat result examples.

- [ ] **Step 2: Update the roadmap current work**

Replace the completed context-limit item under `Now` with contract stabilization and its concrete outcomes:

```markdown
### Stabilize the worker result contract

- publish a versioned JSON Schema;
- use the same result shape for success and failure;
- report only completed delivery artifacts;
- normalize provider-independent failure stages;
- preserve available metrics on failed runs.
```

Remove the duplicate contract-stabilization subsection from `Next`. Do not remove execution budgets or verification reporting.

- [ ] **Step 3: Add retryable delivery to `Later`**

Add this focused roadmap subsection before observability:

```markdown
### Durable delivery artifacts and retries

- persist a Git bundle or durable workspace reference outside the ephemeral worker;
- retry push and pull-request creation without rerunning the LLM;
- make delivery retries idempotent;
- define artifact ownership, integrity checks, retention, and cleanup;
- reuse short-lived repository credentials during each retry attempt.
```

- [ ] **Step 4: Run the complete local test suite**

From `src/services/code-agent` run:

```bash
npm ci
bash -n entrypoint.sh lib/context-limit.sh lib/metrics.sh lib/result.sh tests/*.sh
bash tests/result-schema.test.sh
bash tests/result-contract.test.sh
bash tests/context-limit.test.sh
bash tests/metrics.test.sh
bash tests/entrypoint-context-limit.test.sh
bash tests/entrypoint-lifecycle.test.sh
```

Expected: syntax validation exits zero and every script prints `PASS`.

- [ ] **Step 5: Build and inspect the container image**

From `src/services/code-agent` run:

```powershell
podman build -f dockerfile -t localhost/my-sdlc-agent:0.4 .
podman run --rm --entrypoint bash localhost/my-sdlc-agent:0.4 -c 'dotnet --list-sdks && dotnet --list-runtimes && node --version && git --version && gh --version && rg --version && jq --version && opencode --version && bash -n /usr/local/bin/sdlc-agent /opt/sdlc/lib/*.sh'
```

Expected: build exits zero; .NET 8 and 10, Node.js, Git, GitHub CLI, ripgrep, jq, and OpenCode report versions; shell syntax exits zero.

If Podman or its machine is unavailable, record the exact unavailable check in the handoff and do not claim container verification. The real Ollama task remains deferred as stated in the spec.

- [ ] **Step 6: Check documentation and working-tree scope**

Run:

```bash
rg -n '"taskId"|"repository"|"contextLimitTokens"|"stage"' README.md
git diff --check
git status --short
```

Expected: matches only occur inside the nested version 1 examples or explanatory text, `git diff --check` is silent, and status lists only files from this plan.

- [ ] **Step 7: Commit documentation and roadmap changes**

```bash
git add src/services/code-agent/README.md ROADMAP.md
git commit -m "docs: publish code-agent result contract v1"
```
