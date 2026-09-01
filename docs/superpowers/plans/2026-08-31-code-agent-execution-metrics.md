# Code-Agent Execution Metrics and Configurable Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reliable OpenCode execution metrics and configurable `info`/`debug` logging while keeping worker stdout restricted to its final JSON result.

**Architecture:** `entrypoint.sh` captures OpenCode JSONL under `/tmp`, times only the OpenCode process, discovers and exports the persisted session, and reduces per-step usage with `jq`. Session export is authoritative for tokens; live events provide session discovery and sanitized debug progress.

**Tech Stack:** Bash, jq, OpenCode CLI 1.18.21, Podman

**Spec:** `docs/superpowers/specs/2026-08-31-code-agent-execution-metrics-design.md`

## Global Constraints

- Keep the change inside the ephemeral code-agent worker.
- Do not add services, databases, telemetry frameworks, provider routing, or runtime dependencies.
- Preserve the OpenCode versus deterministic Git/GitHub delivery boundary.
- Never expose `GH_TOKEN` or `GITHUB_TOKEN` to OpenCode.
- Store runtime files under `/tmp`, never in the cloned repository.
- Send logs to stderr and exactly one final JSON result to stdout.
- Accept exactly `LOG_LEVEL=info|debug`, defaulting to `info`.
- Never estimate token data; use JSON `null` when reliable usage is unavailable.
- Do not commit or push any implementation, documentation, spec, or plan changes.
- Ollama is unavailable; leave the real inference smoke test for the user.

## File Structure

- Modify `src/services/code-agent/entrypoint.sh`: logging, event capture, timing, session export, metric reduction, and result JSON.
- Modify `src/services/code-agent/README.md`: configuration, formulas, result examples, data source, limitations, and manual verification.
- Keep `Dockerfile` and `opencode.json.template` unchanged unless pinned CLI inspection proves the agreed commands differ; stop for review before expanding scope.

---

### Task 1: Add configurable worker logging

**Files:**
- Modify: `src/services/code-agent/entrypoint.sh`

**Interfaces:**
- Consumes: optional `LOG_LEVEL`.
- Produces: validated `info` or `debug`; `log()` and `debug()` functions that write only to stderr.

- [ ] **Step 1: Add the default and debug helper**

Implement near the existing logging function:

```bash
LOG_LEVEL="${LOG_LEVEL:-info}"

log() {
    echo "[sdlc-agent] $*" >&2
}

debug() {
    if [[ "$LOG_LEVEL" == "debug" ]]; then
        echo "[sdlc-agent] [debug] $*" >&2
    fi
}
```

Do not log environment dumps, prompts, tool payloads, or commands containing secrets.

- [ ] **Step 2: Add exact-value configuration validation**

After required common variables are validated:

```bash
case "$LOG_LEVEL" in
    info|debug)
        ;;
    *)
        fail "configuration" "Unsupported LOG_LEVEL='$LOG_LEVEL'. Expected info or debug"
        ;;
esac
```

Add to `usage()`:

```text
  LOG_LEVEL
      Default: info
      Supported: info, debug
```

- [ ] **Step 3: Run the initial checks**

Run:

```powershell
bash -n src/services/code-agent/entrypoint.sh
```

Expected: exit code `0`.

Using the built image or disposable harness, invoke with `LOG_LEVEL=trace` and otherwise non-secret placeholder configuration. Expected final stdout JSON:

```json
{
  "status": "failed",
  "stage": "configuration",
  "error": "Unsupported LOG_LEVEL='trace'. Expected info or debug"
}
```

Verify stderr contains no credential value.

---

### Task 2: Capture OpenCode timing and events without stdout leakage

**Files:**
- Modify: `src/services/code-agent/entrypoint.sh`

**Interfaces:**
- Consumes: existing OpenCode command and Task 1 logging.
- Produces: integer `DURATION_MS`, `AGENT_EXIT`, `/tmp/opencode-events.jsonl`, and `/tmp/opencode-stderr.log`.

- [ ] **Step 1: Add temporary paths and a millisecond clock**

Add:

```bash
OPENCODE_EVENTS_FILE="/tmp/opencode-events.jsonl"
OPENCODE_SESSION_FILE="/tmp/opencode-session.json"
OPENCODE_STDERR_FILE="/tmp/opencode-stderr.log"

now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        printf '%s\n' "${EPOCHREALTIME/./}" | cut -c1-13
    else
        date +%s%3N
    fi
}
```

- [ ] **Step 2: Start and stop timing immediately around OpenCode**

Immediately before the `env ... opencode run` pipeline:

```bash
AGENT_STARTED_MS="$(now_ms)"
```

Immediately after it finishes, while `set +e` is still active:

```bash
AGENT_EXIT="${PIPESTATUS[0]}"
AGENT_FINISHED_MS="$(now_ms)"
DURATION_MS="$((AGENT_FINISHED_MS - AGENT_STARTED_MS))"
```

Clone, commit, push, and PR time must remain outside this interval.

- [ ] **Step 3: Capture JSON output**

Add `--format json`. Use this stream shape while retaining the current prompt and model arguments:

```bash
env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    opencode run \
        --auto \
        --format json \
        --model "$MODEL" \
        "$PROMPT" \
    2> >(tee "$OPENCODE_STDERR_FILE" >&2) \
    | tee "$OPENCODE_EVENTS_FILE" >/dev/null
```

Preserve `PIPESTATUS[0]`. Never echo `PROMPT`.

- [ ] **Step 4: Add sanitized debug progress**

Project only safe metadata from valid JSON lines:

```bash
jq -r '
  select(type == "object")
  | [(.type // "unknown"), (.part.tool // empty), (.part.reason // empty)]
  | map(select(length > 0))
  | join(" ")
' "$OPENCODE_EVENTS_FILE"
```

Pass each projected line through `debug`. Never print `.part.text`, tool input/output, raw token objects, or the complete event.

- [ ] **Step 5: Verify with a disposable fake OpenCode**

Use a temporary executable that sleeps at least 100 ms, emits a `step_start` JSON line to stdout, writes a diagnostic to stderr, and exits with a selectable code. Do not add it to the repository.

Assertions:

```bash
test "$DURATION_MS" -ge 100
test "$DURATION_MS" -lt 5000
test "$AGENT_EXIT" -eq 0
jq -e 'select(.type == "step_start")' "$OPENCODE_EVENTS_FILE" >/dev/null
! grep -q '"type":"step_start"' worker.stdout
```

Expected: all pass. Debug projections appear only for `LOG_LEVEL=debug`; OpenCode output never enters worker stdout.

---

### Task 3: Export the session and calculate token metrics

**Files:**
- Modify: `src/services/code-agent/entrypoint.sh`

**Interfaces:**
- Consumes: event file, current project directory, and pinned OpenCode CLI.
- Produces: `SESSION_ID` and nullable `PEAK_CONTEXT_TOKENS`, `INPUT_TOKENS`, `OUTPUT_TOKENS`, `LLM_REQUESTS`.

- [ ] **Step 1: Create a disposable multi-step fixture**

Write this only under `/tmp` during verification:

```json
{
  "messages": [{
    "parts": [
      {
        "type": "step-finish",
        "tokens": {
          "input": 100,
          "output": 10,
          "reasoning": 3,
          "cache": { "read": 900, "write": 0 }
        }
      },
      {
        "type": "step-finish",
        "tokens": {
          "input": 200,
          "output": 20,
          "reasoning": 5,
          "cache": { "read": 1300, "write": 100 }
        }
      },
      { "type": "text", "text": "must not be counted" }
    ]
  }]
}
```

Expected result:

```json
{
  "peakContextTokens": 1600,
  "inputTokens": 300,
  "outputTokens": 30,
  "llmRequests": 2
}
```

The cumulative contexts equal `2600`; the reported peak must be `1600`.

- [ ] **Step 2: Discover the session**

Read the first event session ID:

```bash
SESSION_ID="$(
    jq -r 'select(type == "object") | .sessionID // empty'         "$OPENCODE_EVENTS_FILE" 2>/dev/null     | head -n 1
)"
```

If empty, run `opencode session list --format json --max-count 1` from the cloned repository and extract the first ID using the exact field confirmed in Task 6. Debug-log only the chosen ID and discovery method.

If no ID is available, set all token metrics to shell value `null` and debug-log `OpenCode session ID unavailable`.

- [ ] **Step 3: Export and validate persisted data**

When the session ID exists:

```bash
opencode export "$SESSION_ID" >"$OPENCODE_SESSION_FILE"
jq -e . "$OPENCODE_SESSION_FILE" >/dev/null 2>&1
```

A non-zero export, empty file, or invalid JSON makes all token metrics `null`; it does not fail an otherwise successful worker.

- [ ] **Step 4: Reduce valid model steps**

Use this jq program:

```jq
[
  ..
  | objects
  | select((.type? == "step-finish" or .type? == "step_finish"))
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
```

Extract its four properties into the corresponding shell variables. A null result maps all four to literal `null`.

- [ ] **Step 5: Verify valid and malformed fixtures**

Assert the valid fixture:

```bash
jq -e '
  .peakContextTokens == 1600
  and .inputTokens == 300
  and .outputTokens == 30
  and .llmRequests == 2
' /tmp/calculated-metrics.json
```

Repeat with `{}`, invalid JSON, and a step missing `cache.write`. Expected: no partial or invented metrics; all token fields become null with a debug reason.

- [ ] **Step 6: Add concise metric logs**

At info:

```text
OpenCode metrics: durationMs=<value> peakContextTokens=<value-or-unavailable> llmRequests=<value-or-unavailable>
```

At debug, also log input/output totals, session discovery method, and valid step count. Never dump the exported session.

---

### Task 4: Extend the success JSON safely

**Files:**
- Modify: `src/services/code-agent/entrypoint.sh`

**Interfaces:**
- Consumes: existing success fields and Task 3 metric variables.
- Produces: the existing result plus a numeric/null `metrics` object.

- [ ] **Step 1: Build typed metrics JSON**

Implement:

```bash
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
```

Before this, validate `DURATION_MS` as a non-negative integer. An invalid duration is a worker error because duration is guaranteed once OpenCode starts.

- [ ] **Step 2: Add the object to the existing result**

Pass `--argjson metrics "$METRICS_JSON"` to the final jq command and add:

```jq
metrics: $metrics
```

Do not alter `status`, `taskId`, `repository`, `branch`, `commit`, `pullRequest`, or `model`.

- [ ] **Step 3: Verify numeric metrics**

Capture stdout and assert:

```bash
jq -e '
  .status == "success"
  and (.metrics.durationMs | type) == "number"
  and .metrics.peakContextTokens == 1600
  and .metrics.inputTokens == 300
  and .metrics.outputTokens == 30
  and .metrics.llmRequests == 2
' worker.stdout
```

Expected: exit code `0` and exactly one JSON document in stdout.

- [ ] **Step 4: Verify unavailable usage**

Assert:

```bash
jq -e '
  (.metrics.durationMs | type) == "number"
  and .metrics.peakContextTokens == null
  and .metrics.inputTokens == null
  and .metrics.outputTokens == null
  and .metrics.llmRequests == null
' worker.stdout
```

Expected: metric collection failure alone does not turn worker success into failure.

- [ ] **Step 5: Preserve failure output**

Make fake OpenCode exit `7` and assert:

```bash
jq -e '
  .status == "failed"
  and .stage == "implementation"
  and .error == "OpenCode exited with code 7"
  and (has("metrics") | not)
' worker.stdout
```

Expected: failure duration appears only in stderr; failure JSON stays compatible.

---

### Task 5: Update worker documentation

**Files:**
- Modify: `src/services/code-agent/README.md`

**Interfaces:**
- Consumes: implemented environment and output contracts.
- Produces: documentation matching names, defaults, formulas, and limitations exactly.

- [ ] **Step 1: Document `LOG_LEVEL`**

Under optional variables, document default `info`, allowed values, info/debug behavior, stderr destination, and the prohibition on printing secrets, prompts, file contents, or raw exports.

- [ ] **Step 2: Update the success example**

Add the exact five-field `metrics` object. Show a second compact example or prose explaining that token fields are JSON null when complete persisted usage is unavailable.

- [ ] **Step 3: Document formulas**

Include:

```text
contextTokens per request = input + cache.read + cache.write
peakContextTokens = max(contextTokens across model requests)
inputTokens = sum(input across model requests)
outputTokens = sum(output across model requests)
llmRequests = count(valid step-finish token records)
```

State that reasoning is excluded and no transcript estimate is used.

- [ ] **Step 4: Document the source and streams**

Explain that persisted `opencode export <sessionID>` data is authoritative because live JSON may omit the final `step_finish`.

Document:

```text
stdout -> exactly one final structured result
stderr -> lifecycle and optional sanitized debug logs
exit code -> worker success or failure
```

- [ ] **Step 5: Update the manual Ollama check**

Use model `ollama/qwen3.8:27b-64k`, add `LOG_LEVEL=debug`, separate stdout/stderr redirection, `jq` validation, and checks that a multi-step run reports `llmRequests > 1` and a peak rather than cumulative context. Mark this user-run because Ollama was unavailable during implementation.

- [ ] **Step 6: Check consistency**

Run:

```powershell
rg -n "LOG_LEVEL|durationMs|peakContextTokens|inputTokens|outputTokens|llmRequests|stdout|stderr" src/services/code-agent/README.md src/services/code-agent/entrypoint.sh
```

Expected: names, defaults, and definitions agree; the old success example has been updated.

---

### Task 6: Verify the pinned CLI and Podman image

**Files:**
- Verify: `src/services/code-agent/Dockerfile`
- Verify: `src/services/code-agent/entrypoint.sh`
- Verify: `src/services/code-agent/README.md`

**Interfaces:**
- Consumes: completed implementation and available Podman.
- Produces: recorded commands/exit codes, confirmed OpenCode 1.18.21 behavior, and an explicit deferred Ollama limitation.

- [ ] **Step 1: Run static checks**

```powershell
bash -n src/services/code-agent/entrypoint.sh
git diff --check
git status --short
```

Expected: first two exit `0`; status lists only intended spec, plan, worker, and README changes.

- [ ] **Step 2: Ensure Podman is running**

```powershell
podman machine list
podman info
```

If stopped, run `podman machine start`, then repeat `podman info`. Do not modify Ollama.

- [ ] **Step 3: Build the image**

From `src/services/code-agent`:

```powershell
podman build -t localhost/my-sdlc-agent:metrics .
```

Expected: exit `0`; Dockerfile verification reports OpenCode `1.18.21`.

- [ ] **Step 4: Inspect exact CLI commands**

```powershell
podman run --rm --entrypoint bash localhost/my-sdlc-agent:metrics -lc 'opencode --version; opencode run --help; opencode session list --help; opencode export --help; opencode stats --help'
```

Expected: `run --format json`, JSON session listing, and `export <sessionID>` are available. If flag or field names differ, update only parsing and README to observed 1.18.21 behavior, then repeat Tasks 3–5 checks.

- [ ] **Step 5: Execute all disposable harness checks inside the image**

Verify:

- valid and invalid log levels;
- duration bounds;
- no event leakage to stdout;
- numeric metric success result;
- null metric success result;
- unchanged failure JSON;
- fixture peak `1600` versus cumulative context `2600`.

Record each command and exit code. Persist no generated test file in the repository.

- [ ] **Step 6: Perform final diff and security review**

```powershell
git diff --check
git diff -- src/services/code-agent/entrypoint.sh src/services/code-agent/README.md
rg -n "GH_TOKEN|GITHUB_TOKEN|OPENAI_API_KEY|\.part\.text" src/services/code-agent/entrypoint.sh
```

Confirm secrets are not logged, `env -u GH_TOKEN -u GITHUB_TOKEN` remains, raw content is not debug-logged, and delivery responsibility remains in the wrapper.

- [ ] **Step 7: Report the deferred inference test**

State explicitly that a real OpenCode/Ollama task was not run because Ollama was unavailable. Provide the exact README command for the user; do not describe fixture or CLI tests as end-to-end inference.

## Final Completion Checklist

- [ ] Shell syntax passes.
- [ ] Fixture proves a per-request maximum, not cumulative context.
- [ ] Persisted valid step usage is the only token source.
- [ ] Missing usage produces nulls.
- [ ] Duration covers only OpenCode.
- [ ] Info/debug behavior matches documentation.
- [ ] Stdout contains only final JSON.
- [ ] Existing top-level success fields and failure JSON stay compatible.
- [ ] Podman build passes with OpenCode 1.18.21.
- [ ] README covers formulas, source, logging, limitations, and user-run Ollama verification.
- [ ] No commit or push is created.

