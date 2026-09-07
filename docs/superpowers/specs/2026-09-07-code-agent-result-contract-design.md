# Code-Agent Result Contract v1

## Purpose

Define a stable, truthful JSON result for one ephemeral code-agent worker run. The future SDLC orchestrator must be able to consume the same structure for successful and failed runs, determine which delivery artifacts were actually created, and distinguish configured limits from measured usage.

There are no existing consumers that require compatibility with the current flat result. Version 1 can therefore introduce a clean structure without a transition format.

## Scope

This change covers:

- a versioned result envelope;
- the same sections and fields for success and failure;
- explicit `null` values for unknown or unavailable data;
- stable failure stages and safe human-readable error messages;
- metrics in both success and failure results when available;
- truthful reporting of the Git commit, pushed branch, and pull request;
- a machine-readable JSON Schema;
- contract tests and documentation.

This change does not preserve a repository, commit, or patch outside the worker container. It does not retry commit, push, or pull-request creation after the container exits. Durable delivery artifacts and delivery retry will be added to the roadmap as separate future work.

## Contract

Every invocation writes exactly one JSON document to stdout. Operational logs remain on stderr. The process exits with zero for `success` and non-zero for `failed`.

The version 1 envelope is:

```json
{
  "schemaVersion": 1,
  "status": "success",
  "task": {
    "id": "AIEXEC-123",
    "repository": "owner/repository",
    "baseBranch": "main"
  },
  "execution": {
    "model": "ollama/qwen3.8:27b-64k",
    "contextLimitTokens": 65536
  },
  "delivery": {
    "branch": "ai/AIEXEC-123",
    "commit": "abc123",
    "pullRequest": "https://github.com/owner/repository/pull/123"
  },
  "metrics": {
    "durationMs": 42000,
    "peakContextTokens": 32000,
    "inputTokens": 50000,
    "outputTokens": 8000,
    "llmRequests": 4
  },
  "error": null
}
```

All top-level sections and all fields shown above are required. Unknown, unavailable, or not-yet-created values are represented by JSON `null`; fields are never omitted. Numeric zero remains a measured zero and must not be used to mean unavailable.

`schemaVersion` is the integer `1`. `status` is either `success` or `failed`. A successful result has `error: null`. A failed result has an error object:

```json
{
  "stage": "pull-request",
  "message": "Failed to create pull request"
}
```

No machine-readable error code is included in version 1. The stable `stage` supports orchestration decisions, while `message` is a safe explanation for operators.

For example, a run that committed and pushed its changes but failed to create a pull request returns:

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "task": {
    "id": "AIEXEC-123",
    "repository": "owner/repository",
    "baseBranch": "main"
  },
  "execution": {
    "model": "ollama/qwen3.8:27b-64k",
    "contextLimitTokens": 65536
  },
  "delivery": {
    "branch": "ai/AIEXEC-123",
    "commit": "abc123",
    "pullRequest": null
  },
  "metrics": {
    "durationMs": 42000,
    "peakContextTokens": 32000,
    "inputTokens": 50000,
    "outputTokens": 8000,
    "llmRequests": 4
  },
  "error": {
    "stage": "pull-request",
    "message": "Failed to create pull request"
  }
}
```

## Section Semantics

### Task

`task.id`, `task.repository`, and `task.baseBranch` identify the requested work and target. They contain the validated or best-known configuration. A field is `null` when configuration failed before the worker could establish a valid value.

### Execution

`execution.model` is the selected OpenCode provider/model identifier. `execution.contextLimitTokens` is the configured deployment limit, not measured token usage. It is `null` when the limit was not configured or was invalid.

### Delivery

Delivery fields report completed artifacts, not intent:

- `delivery.commit` becomes the commit SHA only after `git commit` succeeds.
- `delivery.branch` becomes the branch name only after `git push` succeeds.
- `delivery.pullRequest` becomes the pull-request URL only after creation succeeds.

Before the corresponding operation succeeds, the field remains `null`, even when a requested branch name is known. This makes field presence evidence that the artifact reached the stated lifecycle point.

Delivery state is monotonic. A non-null pull request requires a non-null branch and commit. A non-null pushed branch requires a non-null commit.

### Metrics

The metric definitions remain those already documented by the worker. `durationMs` measures the OpenCode execution interval rather than total container lifetime. Token fields are derived from persisted OpenCode session usage.

The worker attempts to collect available metrics after OpenCode exits, including when OpenCode returns a failure status. Metric collection failure never replaces the primary worker failure. Before OpenCode starts, all metric values are `null`. After it starts, `durationMs` is populated when timing succeeds; unavailable token metrics remain `null`.

## Failure Stages

Version 1 defines this closed set of stages:

- `configuration`: required or optional worker configuration is invalid;
- `provider-connectivity`: the selected inference provider cannot be reached;
- `github-authentication`: GitHub credentials or Git credential setup failed;
- `clone`: repository cloning failed;
- `base-branch`: fetching, checking out, or resetting the base branch failed;
- `implementation-branch`: the target branch already exists or local branch creation failed;
- `implementation`: OpenCode failed or produced no repository changes;
- `commit`: committing the implementation failed;
- `push`: pushing the implementation branch failed;
- `pull-request`: creating the pull request failed;
- `worker`: an unexpected wrapper failure occurred outside a more specific stage.

Provider names do not appear in stage values. For example, an Ollama reachability failure uses `provider-connectivity`, keeping the contract provider-independent.

Error messages must not contain credentials, the task prompt, captured stderr, model event payloads, or target-repository file contents.

## Result Generation

A new `src/services/code-agent/lib/result.sh` module will own result state and JSON rendering. It initializes every nullable field, records successful lifecycle transitions, and emits the final envelope. Both expected failures and the global `ERR` trap use the same renderer.

The entrypoint remains responsible for orchestration. It updates result state only after an operation succeeds:

1. Initialize result state from the best-known task and execution configuration.
2. Validate configuration, leaving invalid or unavailable values as `null`.
3. Run provider, GitHub, clone, and branch preparation stages.
4. Measure OpenCode and attempt metric collection after any OpenCode exit.
5. Record the commit SHA after commit succeeds.
6. Record the branch after push succeeds.
7. Record the pull-request URL after PR creation succeeds.
8. Emit one success or failure document.

The renderer must not mask the original failure if optional metric extraction or result-state enrichment fails. If JSON rendering itself cannot complete, the worker may only log a last-resort error to stderr and exit non-zero; producing malformed fallback JSON would violate the contract.

## JSON Schema

`src/services/code-agent/result.schema.json` will use JSON Schema Draft 2020-12. It will:

- require every documented property;
- reject undocumented properties;
- constrain `schemaVersion` to `1`;
- constrain `status` and failure stages to their documented enums;
- allow `null` only where the contract permits it;
- require `error` to be null for success and an object for failure;
- require successful results to contain task identity, model, commit, branch, pull request, and `durationMs`;
- encode delivery ordering invariants where practical.

The schema is the machine-readable source of truth. README examples and prose must agree with it.

## Compatibility and Versioning

The current unversioned flat output is replaced rather than supported in parallel because it has no consumers. Once version 1 is released, additive or semantic changes require deliberate compatibility review. A breaking change requires a new `schemaVersion`; the worker will not emit multiple versions in one document.

## Files Expected to Change

- `src/services/code-agent/lib/result.sh`: result state and rendering.
- `src/services/code-agent/entrypoint.sh`: lifecycle state updates and unified success/failure emission.
- `src/services/code-agent/result.schema.json`: version 1 schema.
- `src/services/code-agent/tests/result-contract.test.sh`: schema, success, failure, and state-transition checks.
- Existing entrypoint tests: assertions updated to the version 1 shape.
- `src/services/code-agent/README.md`: contract, field semantics, failure stages, and examples.
- `ROADMAP.md`: mark context-limit work complete, make contract stabilization current, and add durable artifact storage plus retryable delivery under later work.

## Verification

Implementation verification will include:

1. Shell syntax validation for the entrypoint, result module, and tests.
2. Contract tests for both success and failure documents.
3. Validation of generated documents against `result.schema.json`.
4. Tests showing that all fields remain present and unavailable values are `null`.
5. Tests for failure before OpenCode and failure after metrics are available.
6. Tests for commit, push, and pull-request transitions, including the delivery ordering invariants.
7. A check that stdout contains exactly one valid JSON document and logs remain on stderr.
8. Existing context-limit and metric tests.
9. Container image build and installed-tool inspection when the local Podman environment is available.

The documented Ollama end-to-end smoke test remains deferred while Ollama is unavailable. No claim of end-to-end provider execution will be made without running it.

## Roadmap Follow-Up: Retryable Delivery

Future retryable delivery must persist enough data outside the ephemeral container to reconstruct the committed changes. Candidate artifacts include a Git bundle or a durable workspace reference. A later worker or orchestrator operation can then retry push and pull-request creation without rerunning the LLM. The design must specify artifact ownership, retention, integrity, credentials, idempotency, and cleanup before implementation.
