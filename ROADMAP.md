# AI SDLC Roadmap

This roadmap captures the current direction of the AI SDLC platform. It is intentionally lightweight and will evolve as the proof of concept becomes a complete system.

## Now

### Make the code agent aware of its context limit

Accept the model context-window limit as a worker parameter, initially through an environment variable such as `MODEL_CONTEXT_LIMIT`.

The worker should:

- validate that the value is a positive integer;
- include the configured limit in the coding prompt;
- instruct the agent to preserve enough context to finish and verify the task;
- include the configured limit in the structured result and metrics.

The SDLC orchestrator should remain the source of truth for this value. The worker should not infer it from the model name because deployments of the same model may have different limits.

## Next

### Stabilize the worker result contract

- add a result `schemaVersion`;
- keep success, failure, and metrics fields consistent across model providers;
- distinguish configured limits from measured usage;
- normalize failure stages and error categories;
- document which metrics are guaranteed and which are provider-dependent.

### Add execution budgets

- support an agent execution timeout;
- preserve enough time for deterministic commit, push, and pull-request stages;
- return a clear failure stage when a budget is exceeded;
- allow the orchestrator to select budgets per task and model.

### Improve verification reporting

- capture whether build, tests, linting, and other checks were attempted;
- distinguish passed, failed, skipped, and unavailable checks;
- surface the verification summary in the pull request and structured result;
- avoid treating agent-written claims as verified facts when no corresponding command result is available.

## Later

### Build the SDLC orchestrator

- task discovery and persistence;
- model selection based on task complexity and available context;
- scheduling and concurrency control;
- retry and local-to-cloud fallback policies;
- human approval and review workflows;
- task state transitions and audit history.

### Observability and cost control

- aggregate duration, token usage, failure rate, and verification results;
- compare models by task type, quality, latency, and cost;
- add correlation identifiers across orchestrator, worker, provider, and pull request;
- define retention and redaction rules for logs and prompts;
- expose dashboards and alerts only after the underlying measurements are reliable.

### Security and isolation

- use short-lived, least-privilege repository credentials;
- restrict worker network access where practical;
- strengthen provider-secret isolation;
- define repository and command allow/deny policies;
- record auditable delivery events without storing secrets or sensitive prompt contents.

## Responsibility Boundary

The code-agent worker executes one coding task and performs deterministic repository delivery. It owns measurement and reporting for its own execution.

The future SDLC orchestrator owns cross-task decisions such as scheduling, persistence, model routing, retry and fallback policy, approval workflows, and aggregated analytics.

Keeping this boundary explicit prevents provider-specific or workflow-specific policy from accumulating in the ephemeral worker.
