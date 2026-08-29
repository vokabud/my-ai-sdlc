#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="/workspace"
CONFIG_FILE="${WORKSPACE}/opencode.json"

log() {
    echo "[sdlc-agent] $*" >&2
}

fail() {
    local stage="$1"
    local message="$2"

    # Avoid triggering ERR trap recursively while exiting through fail().
    trap - ERR

    jq -n \
        --arg status "failed" \
        --arg stage "$stage" \
        --arg message "$message" \
        --arg taskId "${TASK_ID:-unknown}" \
        '{
            status: $status,
            taskId: $taskId,
            stage: $stage,
            error: $message
        }'

    exit 1
}

require_env() {
    local name="$1"

    if [[ -z "${!name:-}" ]]; then
        fail "configuration" "Required environment variable '$name' is missing"
    fi
}

usage() {
    cat >&2 <<'EOF'
Usage:
  sdlc-agent implement

Required environment variables:
  REPO
  TASK_ID
  TASK
  GH_TOKEN
  MODEL

Provider-specific variables:

  Ollama:
    MODEL=ollama/qwen3.8:27b-32k
    OLLAMA_URL=http://host:11434/v1

  OpenAI:
    MODEL=openai/<model-name>
    OPENAI_API_KEY=<api-key>

Optional environment variables:
  BASE_BRANCH
      Default: main

  BRANCH
      Default: ai/<TASK_ID>

  COMMIT_MESSAGE
      Default: AI implementation for <TASK_ID>

  PR_TITLE
      Default: AI implementation: <TASK_ID>
EOF
}

if [[ "${1:-}" != "implement" ]]; then
    usage
    exit 2
fi


# ------------------------------------------------------------
# Validate common configuration
# ------------------------------------------------------------

require_env REPO
require_env TASK_ID
require_env TASK
require_env GH_TOKEN
require_env MODEL

BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH="${BRANCH:-ai/${TASK_ID}}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-AI implementation for ${TASK_ID}}"
PR_TITLE="${PR_TITLE:-AI implementation: ${TASK_ID}}"


# ------------------------------------------------------------
# Validate provider-specific configuration
# ------------------------------------------------------------

if [[ "$MODEL" == ollama/* ]]; then
    require_env OLLAMA_URL
elif [[ "$MODEL" == openai/* ]]; then
    require_env OPENAI_API_KEY
else
    fail \
        "configuration" \
        "Unsupported model provider in MODEL='$MODEL'. Expected ollama/... or openai/..."
fi


# ------------------------------------------------------------
# Global error handler
# ------------------------------------------------------------

trap 'fail "worker" "Unexpected worker failure"' ERR


# ------------------------------------------------------------
# Log worker configuration
# ------------------------------------------------------------

log "Task:       $TASK_ID"
log "Repository: $REPO"
log "Base:       $BASE_BRANCH"
log "Branch:     $BRANCH"
log "Model:      $MODEL"


# ------------------------------------------------------------
# Check model provider
# ------------------------------------------------------------

if [[ "$MODEL" == ollama/* ]]; then
    log "Checking Ollama at $OLLAMA_URL"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        "${OLLAMA_URL%/}/models" \
        >/dev/null \
        || fail "ollama" "Cannot reach Ollama at $OLLAMA_URL"

    log "Ollama is reachable"
fi


# ------------------------------------------------------------
# Check GitHub authentication
# ------------------------------------------------------------

log "Checking GitHub authentication"

export GH_TOKEN

gh auth status >/dev/null 2>&1 \
    || fail "github-auth" "GH_TOKEN authentication failed"

log "GitHub authentication OK"


# ------------------------------------------------------------
# Prepare workspace
# ------------------------------------------------------------

log "Preparing workspace"

rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"


# ------------------------------------------------------------
# Clone repository
# ------------------------------------------------------------

log "Cloning $REPO"

gh repo clone "$REPO" "$WORKSPACE" \
    || fail "clone" "Repository clone failed"

cd "$WORKSPACE"


# ------------------------------------------------------------
# Checkout latest base branch
# ------------------------------------------------------------

log "Checking out base branch '$BASE_BRANCH'"

git fetch origin "$BASE_BRANCH" \
    || fail "git" "Failed to fetch base branch '$BASE_BRANCH'"

git checkout "$BASE_BRANCH" \
    || fail "git" "Failed to checkout base branch '$BASE_BRANCH'"

git reset --hard "origin/$BASE_BRANCH" \
    || fail "git" "Failed to reset to origin/$BASE_BRANCH"


# ------------------------------------------------------------
# Make sure target branch does not already exist
# ------------------------------------------------------------

if git ls-remote \
    --exit-code \
    --heads \
    origin \
    "$BRANCH" \
    >/dev/null 2>&1
then
    fail "branch" "Remote branch '$BRANCH' already exists"
fi


# ------------------------------------------------------------
# Create implementation branch
# ------------------------------------------------------------

log "Creating branch '$BRANCH'"

git checkout -b "$BRANCH" \
    || fail "branch" "Failed to create branch '$BRANCH'"


# ------------------------------------------------------------
# Prepare OpenCode configuration
# ------------------------------------------------------------

log "Preparing OpenCode configuration"

cp \
    /opt/sdlc/opencode.json.template \
    "$CONFIG_FILE" \
    || fail "configuration" "Failed to create OpenCode configuration"


# ------------------------------------------------------------
# Run coding agent
# ------------------------------------------------------------

log "Starting OpenCode"

set +e

env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    opencode run \
        --auto \
        --model "$MODEL" \
        "$TASK

You are running inside an isolated ephemeral coding worker.

Rules:
- Work only inside the current repository.
- Inspect the existing implementation before changing files.
- Implement only the requested task.
- Follow existing project conventions.
- Run relevant restore/build/test/lint commands.
- Fix failures introduced by your changes.
- Do not commit.
- Do not push.
- Do not create or modify pull requests.
- Do not install operating-system packages.
- Finish with a concise implementation and verification summary." \
    2>&1 | tee /tmp/opencode-output.log

AGENT_EXIT="${PIPESTATUS[0]}"

set -e


# ------------------------------------------------------------
# Check OpenCode result
# ------------------------------------------------------------

if [[ "$AGENT_EXIT" -ne 0 ]]; then
    fail \
        "implementation" \
        "OpenCode exited with code $AGENT_EXIT"
fi

log "OpenCode completed successfully"


# ------------------------------------------------------------
# Verify that the agent actually changed something
# ------------------------------------------------------------

if git diff --quiet && git diff --cached --quiet; then
    fail \
        "implementation" \
        "Agent completed successfully but repository has no changes"
fi


# ------------------------------------------------------------
# Show resulting changes
# ------------------------------------------------------------

log "Repository changes:"

git status --short >&2

log "Diff statistics:"

git diff --stat >&2


# ------------------------------------------------------------
# Commit changes
# ------------------------------------------------------------

log "Creating commit"

git config user.name "SDLC Coding Agent"
git config user.email "sdlc-agent@users.noreply.github.com"

git add --all

git commit -m "$COMMIT_MESSAGE" \
    || fail "commit" "Git commit failed"

COMMIT_SHA="$(git rev-parse HEAD)"

log "Created commit $COMMIT_SHA"


# ------------------------------------------------------------
# Push branch
# ------------------------------------------------------------

log "Pushing branch '$BRANCH'"

git push \
    --set-upstream \
    origin \
    "$BRANCH" \
    || fail "push" "Git push failed"


# ------------------------------------------------------------
# Build pull request body
# ------------------------------------------------------------

PR_BODY="$(cat <<EOF
Automated implementation for task \`${TASK_ID}\`.

### Task

${TASK}

### Worker

- Model: \`${MODEL}\`
- Base branch: \`${BASE_BRANCH}\`
- Branch: \`${BRANCH}\`
- Commit: \`${COMMIT_SHA}\`

### Agent output

\`\`\`
$(tail -n 80 /tmp/opencode-output.log)
\`\`\`
EOF
)"


# ------------------------------------------------------------
# Create pull request
# ------------------------------------------------------------

log "Creating pull request"

PR_URL="$(
    gh pr create \
        --repo "$REPO" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "$PR_TITLE" \
        --body "$PR_BODY"
)" || fail "pull-request" "Failed to create pull request"

log "Pull request created: $PR_URL"


# ------------------------------------------------------------
# Return machine-readable result
# ------------------------------------------------------------

jq -n \
    --arg status "success" \
    --arg taskId "$TASK_ID" \
    --arg repo "$REPO" \
    --arg branch "$BRANCH" \
    --arg commit "$COMMIT_SHA" \
    --arg pullRequest "$PR_URL" \
    --arg model "$MODEL" \
    '{
        status: $status,
        taskId: $taskId,
        repository: $repo,
        branch: $branch,
        commit: $commit,
        pullRequest: $pullRequest,
        model: $model
    }'