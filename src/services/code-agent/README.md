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
ollama/qwen3.8:27b-32k
openai/<model>
```

This allows the SDLC orchestrator to select different models for different tasks without building different worker images.

For example:

```text
small/local task
    -> ollama/qwen3.8:27b-32k

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
ollama/qwen3.8:27b-32k
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

## Build the worker

From this directory:

```powershell
podman build `
  -t localhost/my-sdlc-agent:0.3 `
  .
```

To force a completely clean build:

```powershell
podman build `
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
  -e MODEL="ollama/qwen3.8:27b-32k" `
  -e OLLAMA_URL="http://192.168.31.116:11434/v1" `
  -e TASK="Implement the requested small test change. Inspect the repository first, follow existing conventions, and run the relevant build and tests." `
  localhost/my-sdlc-agent:0.3 `
  implement
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

## Successful result

The final standard output is intended to be consumed by the SDLC orchestrator.

Example:

```json
{
  "status": "success",
  "taskId": "AIEXEC-123",
  "repository": "owner/repository",
  "branch": "ai/AIEXEC-123",
  "commit": "abc123...",
  "pullRequest": "https://github.com/owner/repository/pull/123",
  "model": "ollama/qwen3.8:27b-32k"
}
```

Human-readable worker logs are written to stderr.

This distinction allows an orchestrator to treat:

```text
stdout -> structured result
stderr -> execution logs
exit code -> process success/failure
```

## Failed result

A failed stage returns non-zero process status and structured JSON similar to:

```json
{
  "status": "failed",
  "taskId": "AIEXEC-123",
  "stage": "implementation",
  "error": "OpenCode exited with code 1"
}
```

Possible stages include configuration, provider connectivity, GitHub authentication, clone, branch creation, implementation, commit, push, and pull-request creation.

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

Before OpenCode is launched, the worker removes `GH_TOKEN` and `GITHUB_TOKEN` from the child process environment.

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
