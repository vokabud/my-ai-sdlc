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

cleanup() {
    rm -rf "$WORKSPACE"
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
  OLLAMA_URL

Optional:

  BASE_BRANCH       default: main
  MODEL             default: ollama/qwen3.8:27b-32k
  BRANCH            default: ai/<TASK_ID>
  COMMIT_MESSAGE    default: AI implementation for <TASK_ID>
  PR_TITLE          default: AI implementation: <TASK_ID>
EOF
}

if [[ "${1:-}" != "implement" ]]; then
    usage
    exit 2
fi

require_env REPO
require_env TASK_ID
require_env TASK
require_env GH_TOKEN
require_env OLLAMA_URL

BASE_BRANCH="${BASE_BRANCH:-main}"
MODEL="${MODEL:-ollama/qwen3.8:27b-32k}"
BRANCH="${BRANCH:-ai/${TASK_ID}}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-AI implementation for ${TASK_ID}}"
PR_TITLE="${PR_TITLE:-AI implementation: ${TASK_ID}}"

export GH_TOKEN

trap 'fail "worker" "Unexpected worker failure"' ERR

log "Task:       $TASK_ID"
log "Repository: $REPO"
log "Base:       $BASE_BRANCH"
log "Branch:     $BRANCH"
log "Model:      $MODEL"

#
# 1. Validate external dependencies
#

log "Checking Ollama..."

curl \
    --fail \
    --silent \
    --show-error \
    --max-time 10 \
    "${OLLAMA_URL%/}/models" \
    >/dev/null \
    || fail "ollama" "Cannot reach Ollama at $OLLAMA_URL"

log "Checking GitHub authentication..."

gh auth status >/dev/null 2>&1 \
    || fail "github-auth" "GH_TOKEN authentication failed"

#
# 2. Fresh workspace
#

rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"

log "Cloning repository..."

gh repo clone "$REPO" "$WORKSPACE" \
    || fail "clone" "Repository clone failed"

cd "$WORKSPACE"

#
# 3. Prepare branch
#

log "Checking out base branch..."

git fetch origin "$BASE_BRANCH"

git checkout "$BASE_BRANCH"

git reset --hard "origin/$BASE_BRANCH"

if git ls-remote \
    --exit-code \
    --heads origin "$BRANCH" \
    >/dev/null 2>&1;
then
    fail "branch" "Remote branch '$BRANCH' already exists"
fi

git checkout -b "$BRANCH"

#
# 4. Generate OpenCode config
#

sed \
    "s|__OLLAMA_URL__|${OLLAMA_URL}|g" \
    /opt/sdlc/opencode.json.template \
    > "$CONFIG_FILE"

#
# 5. Agent implementation
#

log "Starting OpenCode..."

set +e

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

if [[ "$AGENT_EXIT" -ne 0 ]]; then
    fail "implementation" "OpenCode exited with code $AGENT_EXIT"
fi

#
# 6. Ensure something actually changed
#

if git diff --quiet && git diff --cached --quiet; then
    fail "implementation" "Agent completed but repository has no changes"
fi

#
# 7. Show deterministic diff
#

log "Changed files:"

git status --short >&2

log "Diff summary:"

git diff --stat >&2

#
# 8. Commit
#

git config user.name "SDLC Coding Agent"
git config user.email "sdlc-agent@users.noreply.github.com"

git add --all

git commit -m "$COMMIT_MESSAGE" \
    || fail "commit" "Git commit failed"

COMMIT_SHA="$(git rev-parse HEAD)"

#
# 9. Push
#

log "Pushing branch..."

git push --set-upstream origin "$BRANCH" \
    || fail "push" "Git push failed"

#
# 10. Create PR
#

log "Creating pull request..."

PR_BODY="$(cat <<EOF
Automated implementation for task \`${TASK_ID}\`.

### Task

${TASK}

### Worker

- Model: \`${MODEL}\`
- Base branch: \`${BASE_BRANCH}\`
- Commit: \`${COMMIT_SHA}\`

### Agent summary

\`\`\`
$(tail -n 80 /tmp/opencode-output.log)
\`\`\`
EOF
)"

PR_URL="$(
    gh pr create \
        --repo "$REPO" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "$PR_TITLE" \
        --body "$PR_BODY"
)" || fail "pull-request" "Failed to create pull request"

#
# 11. Machine-readable result
#

jq -n \
    --arg status "success" \
    --arg taskId "$TASK_ID" \
    --arg repo "$REPO" \
    --arg branch "$BdRANCH" \
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