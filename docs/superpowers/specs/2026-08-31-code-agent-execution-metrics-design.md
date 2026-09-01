# Code-Agent Execution Metrics and Configurable Logging

## Purpose

Add lightweight execution metrics and configurable logging to the existing ephemeral code-agent worker. Keep the change inside the deterministic worker wrapper and preserve the boundary between OpenCode coding work and Git/GitHub delivery.

The implementation must not introduce services, databases, telemetry frameworks, provider routing, or other infrastructure.

## Scope

The worker will report:

- OpenCode execution duration;
- peak input context across individual model requests;
- cumulative OpenCode input tokens;
- cumulative OpenCode output tokens;
- number of model requests.

The worker will also accept `LOG_LEVEL=info|debug`, defaulting to `info`.

Broader roadmap metrics such as total worker duration, diff statistics, configured context limit, and verification-command reporting remain separate future work.

## Architecture

The change remains local to `src/services/code-agent/entrypoint.sh`. OpenCode continues to inspect and modify the target repository. The wrapper continues to own configuration, cloning, branch creation, measurement, commit, push, pull-request creation, and the final structured result.

No runtime-generated metric or event file will be placed in the cloned repository. Temporary files will be stored under `/tmp` in the ephemeral container.

The worker will:

1. Record a monotonic timestamp immediately before invoking OpenCode.
2. Invoke `opencode run --format json` and capture its JSONL event stream in `/tmp`.
3. Keep OpenCode events out of stdout so stdout contains only the final worker result.
4. Record the ending timestamp immediately after OpenCode exits and calculate `durationMs`.
5. Read the OpenCode session ID from the captured event stream.
6. If the event stream does not contain a session ID, query the most recent session for the current project with `opencode session list --format json`.
7. Export the persisted session with `opencode export <sessionID>` to `/tmp`.
8. Reduce the persisted per-step usage records with `jq`.
9. Add a structured `metrics` object to the existing success result.

Persisted session export is the authoritative token source. The live JSON event stream is used to locate the session and, at debug level, to expose sanitized execution diagnostics. This avoids relying on the final live `step_finish`, which OpenCode may fail to emit even when it persists the completed step.

Direct access to OpenCode's SQLite database is deliberately excluded because it would couple the worker to internal storage details.

## Metric Definitions

For one OpenCode model step:

```text
contextTokens = tokens.input + tokens.cache.read + tokens.cache.write
```

The result metrics are:

```text
durationMs
  = monotonic time immediately after OpenCode exits
  - monotonic time immediately before OpenCode starts

peakContextTokens
  = maximum contextTokens across exported step-finish records

inputTokens
  = sum of tokens.input across exported step-finish records

outputTokens
  = sum of tokens.output across exported step-finish records

llmRequests
  = number of step-finish records containing a valid tokens object
```

`inputTokens` follows the meaning of OpenCode's `tokens.input` field and therefore does not include cache fields. Cache read and write tokens are included in the per-request context calculation because they represent input-side context for that request.

Reasoning tokens are not included in `peakContextTokens` or `outputTokens`. No token metric will be estimated from transcript text or repository size.

## Result Contract

The existing top-level success fields remain unchanged. A successful result gains a `metrics` object:

```json
{
  "status": "success",
  "taskId": "AIEXEC-123",
  "repository": "owner/repository",
  "branch": "ai/AIEXEC-123",
  "commit": "abc123",
  "pullRequest": "https://github.com/owner/repository/pull/123",
  "model": "ollama/qwen3.8:27b-64k",
  "metrics": {
    "durationMs": 123456,
    "peakContextTokens": 42000,
    "inputTokens": 300000,
    "outputTokens": 12000,
    "llmRequests": 20
  }
}
```

If persisted usage cannot be obtained or validated, the worker will not fabricate it. Token metrics will be `null`, while `durationMs` remains available whenever OpenCode was started:

```json
{
  "durationMs": 123456,
  "peakContextTokens": null,
  "inputTokens": null,
  "outputTokens": null,
  "llmRequests": null
}
```

Failure to collect optional usage data will not by itself fail an otherwise successful coding run. The reason will be recorded in debug logs.

The existing failure-result shape will remain unchanged. When OpenCode fails, its measured duration will be written to stderr rather than adding a new metrics contract to failure results in this change.

## Logging

`LOG_LEVEL` is optional and defaults to `info`. Supported values are exactly `info` and `debug`; any other value is a configuration error.

At `info`, stderr will contain lifecycle events such as configuration validation, provider check, clone, OpenCode start and completion, delivery stages, and a concise metric summary.

At `debug`, stderr will additionally contain:

- the OpenCode session ID;
- temporary diagnostic file paths;
- the method used to discover the session;
- the count of valid model steps;
- metric-extraction decisions and failures;
- sanitized OpenCode progress events.

Logs must never include credentials. Prompts, target-repository file contents, raw token-bearing session exports, and other potentially sensitive payloads will not be dumped merely because debug logging is enabled.

All operational logs go to stderr. Stdout is reserved for the single final machine-readable worker result. This corrects the current behavior in which `tee` can forward OpenCode output to stdout.

## Error Handling

The OpenCode exit code remains authoritative for coding-run success. Capturing events must preserve the actual OpenCode exit code across the shell pipeline.

Metric extraction will validate that the exported structure contains usable per-step token objects. Missing, malformed, or incomplete usage produces null token metrics and a debug diagnostic rather than guessed values.

If the live stream has no session ID, the worker will try the most recent session for the current project. Because the worker is an isolated, single-task container, this fallback does not introduce cross-task ambiguity under the supported architecture.

## Files Expected to Change

- `src/services/code-agent/entrypoint.sh`: timing, event capture, session export, metric reduction, log-level handling, and stdout/stderr correction.
- `src/services/code-agent/README.md`: environment-variable documentation, exact metric definitions, result examples, logging behavior, data source, and limitations.

No target-repository code, OpenCode template architecture, provider routing, or Git/GitHub ownership will change.

## Verification

Implementation verification will include:

1. Shell syntax validation.
2. Fixture-based `jq` checks with multiple model steps.
3. A proof that `peakContextTokens` is the maximum per-request context and not cumulative usage.
4. Checks for `info`, `debug`, and invalid `LOG_LEVEL` behavior.
5. Validation that stdout contains only valid final JSON and operational output is on stderr.
6. Container image build with Podman.
7. Inspection of the pinned OpenCode 1.18.21 CLI inside the built image.

Ollama is currently unavailable. A real OpenCode/Ollama task will therefore remain a documented manual verification step for the user and will not be claimed as completed during implementation.

## Documentation Outcome

The README will state:

- what each metric means;
- that persisted OpenCode session export is the authoritative usage source;
- why live JSON alone is insufficient;
- how unavailable metrics are represented;
- how to configure `LOG_LEVEL`;
- which output stream carries logs and which carries the final result;
- how to perform the deferred OpenCode/Ollama smoke test.
