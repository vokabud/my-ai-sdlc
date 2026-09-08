# SDLC Code Agent

Ephemeral coding worker used by the AI SDLC platform to implement coding tasks using a configurable LLM provider.

The worker is packaged as a container and is designed to:

1. Receive a coding task.
2. Clone the target GitHub repository.
3. Create an isolated implementation branch.
4. Run OpenCode with the configured model.
5. Let the coding agent inspect, modify, build, and test the repository.
6. Commit the resulting changes.
7. Push the branch.
8. Create a pull request.
9. Return a machine-readable JSON result.
10. Exit.

The container is disposable. A new worker should normally be created for every task.

## Architecture

```text
SDLC Orchestrator
        |
        | starts container
        v
+---------------------------+
| SDLC Code Agent           |
|                           |
| entrypoint.sh             |
|   |                       |
|   +-- clone repository    |
|   +-- create branch       |
|   |                       |
|   +--> OpenCode ----------+----> LLM Provider
|   |       |               |        |
|   |       +-- inspect     |        +-- Ollama / Qwen
|   |       +-- edit        |        |
|   |       +-- build       |        +-- OpenAI
|   |       +-- test        |
|   |                       |
|   +-- commit              |
|   +-- push                |
|   +-- create PR           |
|                           |
+---------------------------+
        |
        v
JSON result
```

OpenCode is responsible for coding work.

The deterministic worker wrapper is responsible for Git and GitHub delivery.

## Responsibilities

### OpenCode / LLM

The coding agent may:

* inspect repository files;
* search the codebase;
* modify files;
* run project commands;
* restore dependencies;
* build;
* run tests;
* run linters and other repository verification commands.

The coding agent must not:

* commit changes;
* push branches;
* create pull requests;
* modify pull requests;
* install operating-system packages.

### Worker wrapper

`entrypoint.sh` is responsible for:

* validating configuration;
* checking model provider connectivity;
* authenticating with GitHub;
* cloning the repository;
* checking out the base branch;
* creating the implementation branch;
* invoking OpenCode;
* checking that changes were actually produced;
* committing changes;
* pushing the branch;
* creating the pull request;
* returning structured output.

This separation is intentional.

The LLM performs non-deterministic coding work, while repository delivery remains deterministic.

## Supported model providers

The model is selected for each worker invocation through the `MODEL` environment variable.

The value uses the OpenCode `provider/model` format.

Examples:

```text
ollama/qwen3.8:27b-64k
openai/<model>
```

This allows the SDLC orchestrator to select different models for different tasks without building different worker images.

For example:

```text
small/local task
    -> ollama/qwen3.8:27b-64k

complex task
    -> openai/<model>
```

Provider selection belongs to the orchestrator, not to the coding worker.

## Environment variables

### Required

`REPO`

GitHub repository to clone.

Example:

```text
owner/repository
```

`TASK_ID`

Unique task identifier.

Example:

```text
AIEXEC-123
```

`TASK`

Implementation instructions passed to the coding agent.

`GH_TOKEN`

GitHub credential used by the deterministic wrapper for clone, push, and pull-request operations.

The token is removed from the OpenCode process environment before the coding agent is started.

`MODEL`

OpenCode model identifier.

Example:

```text
ollama/qwen3.8:27b-64k
```

### Ollama

When `MODEL` starts with `ollama/`, the following variable is required:

`OLLAMA_URL`

Example:

```text
http://192.168.31.116:11434/v1
```

### OpenAI

When `MODEL` starts with `openai/`, the following variable is required:

`OPENAI_API_KEY`

### Optional

`MODEL_CONTEXT_LIMIT`

Positive integer context-window limit in tokens for this specific model deployment.
The worker includes it in the coding prompt as planning guidance. When the selected
model already has a complete `limit` definition in `opencode.json.template`, as the
local Qwen models do, the worker also overrides that model's OpenCode context limit.
It does not create incomplete model definitions for catalog-backed providers.

The inference provider remains responsible for enforcing the actual context window,
so this value must not exceed the deployed model's real limit.

When omitted, OpenCode uses its existing provider/model configuration. The worker
reports the configured value separately from measured token usage.

`BASE_BRANCH`

Default:

```text
main
```

`BRANCH`

Default:

```text
ai/<TASK_ID>
```

`COMMIT_MESSAGE`

Default:

```text
AI implementation for <TASK_ID>
```

`PR_TITLE`

Default:

```text
AI implementation: <TASK_ID>
```

`LOG_LEVEL`

Optional logging level. The default is `info`; the only allowed values are `info` and `debug`.

At `info`, logs contain worker/OpenCode lifecycle messages and a concise metric summary. At `debug`, logs additionally contain sanitized OpenCode event metadata, temporary diagnostic paths, and metric diagnostics. Logs are written to stderr. Debug logging never intentionally prints credentials, prompts, target file contents, tool payloads, raw events, the raw session export, or captured OpenCode stderr. Failures report safe metadata such as the exit code, duration, and captured stderr byte/line counts.

## Build the worker

From this directory:

```powershell
podman build `
  -f dockerfile `
  -t localhost/my-sdlc-agent:0.3 `
  .
```

To force a completely clean build:

```powershell
podman build `
  -f dockerfile `
  --no-cache `
  -t localhost/my-sdlc-agent:0.3 `
  .
```

## Verify the image

Check the installed tooling:

```powershell
podman run --rm `
  --entrypoint bash `
  localhost/my-sdlc-agent:0.3 `
  -c 'dotnet --list-sdks && dotnet --list-runtimes && node --version && git --version && gh --version && rg --version && opencode --version'
```

The worker currently expects the image to contain at least:

* .NET 8 SDK/runtime
* .NET 10 SDK/runtime
* Node.js
* Git
* GitHub CLI
* ripgrep
* jq
* curl
* OpenCode

## GitHub authentication

First check whether GitHub CLI on the host is authenticated:

```powershell
gh auth status
```

If it is already authenticated, expose its token to the current PowerShell session:

```powershell
$env:GH_TOKEN = gh auth token
```

Check without printing the secret:

```powershell
if ($env:GH_TOKEN) {
    "GH_TOKEN is set"
} else {
    "GH_TOKEN is NOT set"
}
```

Do not commit GitHub tokens or other credentials to this repository.

## Test GitHub authentication inside the container

```powershell
podman run --rm `
  -e GH_TOKEN="$env:GH_TOKEN" `
  --entrypoint bash `
  localhost/my-sdlc-agent:0.3 `
  -c 'gh auth status'
```

This test does not run the coding agent.

## Manual end-to-end test with local Ollama

Make sure Ollama is reachable from the machine running Podman.

For example:

```powershell
curl http://192.168.31.116:11434/v1/models
```

Then run:

```powershell
podman run --rm `
  -e GH_TOKEN="$env:GH_TOKEN" `
  -e REPO="OWNER/REPOSITORY" `
  -e BASE_BRANCH="main" `
  -e TASK_ID="poc-local-001" `
  -e MODEL="ollama/qwen3.8:27b-64k" `
  -e OLLAMA_URL="http://192.168.31.116:11434/v1" `
  -e LOG_LEVEL="debug" `
  -e TASK="Implement the requested small test change. Inspect the repository first, follow existing conventions, and run the relevant build and tests." `
  localhost/my-sdlc-agent:0.3 `
  implement 1> result.json 2> worker.log
```

Replace `OWNER/REPOSITORY` and the task text with the repository and test task you actually want to use.

A successful run should:

```text
clone
  -> branch
  -> OpenCode
  -> Qwen
  -> modify repository
  -> verify
  -> commit
  -> push
  -> create PR
  -> JSON result
```

Validate the separate result stream and confirm that more than one LLM request was recorded:

```powershell
jq -e '.status == "success" and (.metrics.durationMs | type) == "number" and (.metrics.llmRequests > 1)' result.json
```

For a manual proof that `peakContextTokens` is a maximum rather than a sum, compare it with the exported session’s valid `step_finish` records. For each record calculate `input + cache.read + cache.write`; the reported peak must equal the largest per-request value, while `inputTokens` and `outputTokens` are the corresponding sums. Reasoning tokens are excluded.

The Ollama smoke test is user-run/deferred because Ollama is currently unavailable in this environment.

## Manual end-to-end test with OpenAI

Set the API key in the current PowerShell session.

Do not store the key in this repository.

Then run:

```powershell
podman run --rm `
  -e GH_TOKEN="$env:GH_TOKEN" `
  -e OPENAI_API_KEY="$env:OPENAI_API_KEY" `
  -e REPO="OWNER/REPOSITORY" `
  -e BASE_BRANCH="main" `
  -e TASK_ID="poc-openai-001" `
  -e MODEL="openai/<MODEL>" `
  -e TASK="Implement the requested small test change. Inspect the repository first, follow existing conventions, and run the relevant build and tests." `
  localhost/my-sdlc-agent:0.3 `
  implement
```

Replace `<MODEL>` with the OpenCode/OpenAI model configured for the test.

## Result contract v1

The final standard output is a versioned JSON document intended for the SDLC orchestrator. A successful run exits with zero and emits a document such as:

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

A failed run exits non-zero and uses the same shape. For example, a run that committed and pushed its changes but failed to create a pull request emits:

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

All sections and fields are always present. `null` means unknown, unavailable, or not yet created; zero is a measured value. `delivery.commit` proves local commit success, `delivery.branch` proves push success, and `delivery.pullRequest` proves pull-request creation.

### `task`

`task.id`, `task.repository`, and `task.baseBranch` identify the requested work and target. A field is `null` when configuration failed before the worker established a valid value.

### `execution`

`execution.model` is the selected OpenCode provider/model identifier. `execution.contextLimitTokens` is configuration rather than measured usage. It is a JSON number when `MODEL_CONTEXT_LIMIT` is configured and valid, and `null` when the worker relies on OpenCode defaults or rejects the value.

### `delivery`

Delivery fields report completed artifacts. `delivery.commit` is recorded after `git commit` succeeds, `delivery.branch` after `git push` succeeds, and `delivery.pullRequest` after pull-request creation succeeds. Until then, each field remains `null`, even when the intended branch name is known.

### `metrics`

`metrics.durationMs` covers OpenCode execution rather than the full container lifetime. The supported Linux container measures it with the monotonic `/proc/uptime` clock. The token fields are `null` when complete, valid persisted usage is unavailable.

Token metrics are calculated from valid `step_finish`/`step-finish` records in persisted `opencode export <sessionID>` data:

* per-request context = `input + cache.read + cache.write`;
* `peakContextTokens` = maximum individual per-request context;
* `inputTokens` = sum of `input`;
* `outputTokens` = sum of `output`;
* `llmRequests` = count of valid step-finish records.

Reasoning tokens are excluded. Persisted session data is authoritative. Live `opencode run --format json` output is used for session discovery and debug metadata and may omit the final step-finish record.

### `error`

Successful results contain `error: null`. Failed results contain a safe operator message and exactly one of these stages: `configuration`, `provider-connectivity`, `github-authentication`, `clone`, `base-branch`, `implementation-branch`, `implementation`, `commit`, `push`, `pull-request`, or `worker`.

Provider names do not appear in stage values. The `worker` stage covers an unexpected wrapper failure outside a more specific stage. Error messages do not contain credentials, the task prompt, captured stderr, model event payloads, or target-repository file contents.

Human-readable worker logs are written to stderr. The pull-request body contains deterministic worker metadata and a static execution and metrics summary. It does not publish the raw task prompt, OpenCode events, or captured OpenCode stderr.

```text
stdout -> exactly one final result
stderr -> lifecycle and sanitized debug logs
exit code -> success/failure
```

## Development workflow

When modifying this worker:

1. Change the worker files.
2. Rebuild the container image.
3. Verify installed tools.
4. Run a small manual task.
5. Inspect the produced branch and pull request.
6. Confirm that the requested build/tests were executed.
7. Confirm that Git/GitHub delivery was performed by the wrapper rather than the coding agent.

Prefer small deterministic changes to `entrypoint.sh`.

Provider-specific coding behavior should normally be configured through OpenCode rather than implemented directly in the shell wrapper.

## Security notes

Never commit:

* `GH_TOKEN`
* `OPENAI_API_KEY`
* other provider API keys
* repository credentials

GitHub credentials belong to the deterministic wrapper.

For every OpenCode CLI invocation (`run`, `session list`, and `export`), the worker removes `GH_TOKEN` and `GITHUB_TOKEN` from the child process environment.

Provider credentials required for inference are necessarily available to the corresponding provider integration.

The current worker is a PoC. Credential isolation, network restrictions, repository permissions, secret management, and sandbox hardening should be reviewed before production use.

## Current scope

This service is intentionally small.

It is a coding worker, not the complete SDLC orchestrator.

Responsibilities such as:

* discovering tasks;
* deciding which tasks should run;
* selecting the appropriate model;
* retries and fallback policies;
* human approval;
* planning;
* review;
* scheduling;
* task state persistence;

belong outside this service.

A future orchestrator may therefore make decisions such as:

```text
Task
 |
 +-- choose local model
 |       |
 |       +--> code-agent
 |
 +-- choose cloud model
 |       |
 |       +--> code-agent
 |
 +-- local attempt failed
         |
         +--> retry using cloud model
```

The code-agent itself should remain provider-agnostic wherever practical.
