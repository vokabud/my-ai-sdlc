# AI SDLC Roadmap

This roadmap captures the current direction of the AI SDLC platform. It is intentionally lightweight and will evolve as the proof of concept becomes a complete system.

## Now

### Stabilize the worker result contract

- publish a versioned JSON Schema;
- use the same result shape for success and failure;
- report only completed delivery artifacts;
- normalize provider-independent failure stages;
- preserve available metrics on failed runs.

## Next

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

### Durable delivery artifacts and retries

- persist a Git bundle or durable workspace reference outside the ephemeral worker;
- retry push and pull-request creation without rerunning the LLM;
- make delivery retries idempotent;
- define artifact ownership, integrity checks, retention, and cleanup;
- reuse short-lived repository credentials during each retry attempt.

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
