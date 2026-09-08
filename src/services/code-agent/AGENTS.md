# AGENTS.md

## Project purpose

This directory contains the SDLC Code Agent: an ephemeral container worker that executes one coding task against one Git repository and then exits.

The intended lifecycle is:

```text
receive task
-> clone repository
-> create branch
-> run OpenCode
-> verify changes exist
-> commit
-> push
-> create pull request
-> return JSON
-> exit
```

## Architecture boundary

Keep a strict separation between AI coding and deterministic delivery.

### OpenCode / LLM owns

* repository inspection;
* code search;
* file modifications;
* restore;
* build;
* tests;
* linting;
* implementation-related verification.

### `entrypoint.sh` owns

* configuration validation;
* provider connectivity checks;
* GitHub authentication;
* repository clone;
* branch creation;
* commit;
* push;
* pull-request creation;
* final structured result.

Do not move commit, push, or PR creation into the LLM prompt.

Do not give the coding agent responsibility for repository delivery.

## Provider model

The worker is multi-provider.

The selected model is passed through:

```text
MODEL=<provider>/<model>
```

Examples:

```text
ollama/qwen3.8:27b-32k
openai/<model>
```

Provider/model selection is made outside this service by the SDLC orchestrator.

Do not hard-code a default model into the worker unless there is an explicit requirement to do so.

Provider-specific configuration should remain minimal.

## Credentials

Never add credentials to source files.

Never commit:

```text
GH_TOKEN
OPENAI_API_KEY
```

or any other provider secret.

`GH_TOKEN` belongs to the deterministic wrapper and must not intentionally be exposed to the OpenCode subprocess.

Do not change this boundary without an explicit security reason.

## OpenCode

OpenCode is the coding-agent runtime.

Configuration is based on:

```text
opencode.json.template
```

The actual model is supplied to `opencode run` using `--model`.

The coding prompt must continue to tell the agent:

* work only in the cloned repository;
* inspect before modifying;
* implement only the requested task;
* follow repository conventions;
* run relevant verification;
* do not commit;
* do not push;
* do not create pull requests;
* do not install OS packages.

## Container

The image should contain the development tools needed by target repositories.

The current baseline includes:

```text
.NET 8
.NET 10
Node.js
Git
GitHub CLI
ripgrep
jq
curl
OpenCode
```

Do not make the LLM dynamically install operating-system packages as part of normal task execution.

If a generally required runtime or tool is missing, prefer adding it to the Docker image.

## Shell changes

`entrypoint.sh` is orchestration code.

Keep it deterministic and simple.

When changing it:

* preserve strict error handling;
* return non-zero exit codes for failures;
* preserve machine-readable failure output;
* write operational logs to stderr;
* keep final result JSON on stdout;
* quote shell variables;
* never print secrets.

Avoid putting application-specific implementation logic into the worker.

## Output contract

[`result.schema.json`](result.schema.json) is the authoritative version 1 output contract. The entrypoint writes exactly one result document to stdout and operational logs to stderr.

Success uses the nested contract and records completed delivery artifacts:

```json
{
  "schemaVersion": 1,
  "status": "success",
  "task": {"id": "AIEXEC-123", "repository": "owner/repository", "baseBranch": "main"},
  "execution": {"model": "openai/example", "contextLimitTokens": 65536},
  "delivery": {"branch": "ai/AIEXEC-123", "commit": "abc123", "pullRequest": "https://github.com/owner/repository/pull/1"},
  "metrics": {"durationMs": 42, "peakContextTokens": 30, "inputTokens": 20, "outputTokens": 10, "llmRequests": 1},
  "error": null
}
```

Failure uses the same sections. Unavailable or not-yet-created values remain `null`:

```json
{
  "schemaVersion": 1,
  "status": "failed",
  "task": {"id": "AIEXEC-123", "repository": "owner/repository", "baseBranch": "main"},
  "execution": {"model": "openai/example", "contextLimitTokens": null},
  "delivery": {"branch": null, "commit": null, "pullRequest": null},
  "metrics": {"durationMs": 42, "peakContextTokens": null, "inputTokens": null, "outputTokens": null, "llmRequests": null},
  "error": {"stage": "commit", "message": "Git commit failed"}
}
```

All sections and fields are always present. Record a delivery field only after that step succeeds: `delivery.commit` proves local commit success, `delivery.branch` proves push success, and `delivery.pullRequest` proves pull-request creation.

Treat this output as an API contract with the future SDLC orchestrator. Use only failure stages allowed by the schema.

Avoid changing it unnecessarily.

## Verification

Before considering a worker change complete:

1. Build the container image.
2. Confirm required runtimes and tools are present.
3. Run an isolated manual task.
4. Confirm OpenCode can inspect and modify the target repository.
5. Confirm relevant repository build/tests execute.
6. Confirm the wrapper creates the commit.
7. Confirm the wrapper pushes the branch.
8. Confirm the wrapper creates the pull request.
9. Confirm the worker returns valid JSON.
10. Confirm the container exits.

Do not claim a change works without running the relevant verification.

## Scope

This project is the execution worker.

It is not responsible for:

* GitHub issue polling;
* task persistence;
* SDLC state machines;
* planning workflows;
* human approval;
* model routing policy;
* retries/fallback policy;
* review orchestration;
* scheduling.

Those responsibilities belong to the higher-level SDLC orchestrator.

When implementing new functionality, preserve this boundary unless the task explicitly changes the architecture.
