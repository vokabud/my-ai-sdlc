#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
MOCK_BIN="$TEST_ROOT/mock-bin"
TEST_TASK="Create implemented.txt"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

validate_result_schema() {
    local result_file="$1"

    python3 "$SCRIPT_DIR/validate-result-schema.py" \
        "$SERVICE_DIR/result.schema.json" \
        "$result_file" \
        || fail_test "entrypoint result must match result.schema.json"
}

assert_single_json_document() {
    local result_file="$1"

    jq -se 'length == 1' "$result_file" >/dev/null \
        || fail_test "entrypoint must emit exactly one JSON value"
}

assert_entrypoint_owns_success_exit() {
    local -a executable_statements
    local statement_count

    mapfile -t executable_statements < <(
        awk '
            /^[[:space:]]*($|#)/ { next }
            {
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
                print
            }
        ' "$SERVICE_DIR/entrypoint.sh"
    )
    statement_count="${#executable_statements[@]}"

    (( statement_count >= 2 )) \
        || fail_test "entrypoint must end with result emission and an explicit process exit"
    [[ "${executable_statements[statement_count - 1]}" == "exit 0" ]] \
        || fail_test "entrypoint must explicitly own the successful exit status"
    [[ "${executable_statements[statement_count - 2]}" == "result_emit_success" ]] \
        || fail_test "entrypoint must emit the success result before exiting"
}

run_unsupported_command_test() {
    local result_file="$TEST_ROOT/unsupported.json"
    local error_file="$TEST_ROOT/unsupported.log"
    local exit_code

    set +e
    "$SERVICE_DIR/entrypoint.sh" unsupported \
        > "$result_file" \
        2> "$error_file"
    exit_code="$?"
    set -e

    [[ "$exit_code" -eq 1 ]] \
        || fail_test "unsupported command must exit 1, got $exit_code"
    assert_single_json_document "$result_file"
    jq -e \
        --arg message "Unsupported command; expected 'implement'" '
        .status == "failed"
        and .error == {stage:"configuration",message:$message}
    ' "$result_file" >/dev/null \
        || fail_test "unsupported command must emit a configuration failure"
    grep -q '^Usage:' "$error_file" \
        || fail_test "unsupported command must write usage to stderr"
}

run_credential_url_failure_test() {
    local fake_bin="$TEST_ROOT/provider-bin"
    local result_file="$TEST_ROOT/provider-failure.json"
    local error_file="$TEST_ROOT/provider-failure.log"
    local exit_code

    mkdir -p "$fake_bin"
    cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
    chmod +x "$fake_bin/curl"

    set +e
    PATH="$fake_bin:$PATH" \
    REPO="owner/repository" \
    TASK_ID="provider-failure-test" \
    TASK="Test task" \
    GH_TOKEN="test-token" \
    MODEL="ollama/test-model" \
    OLLAMA_URL="http://user:super-secret@ollama.internal:11434/v1" \
        "$SERVICE_DIR/entrypoint.sh" implement \
        > "$result_file" \
        2> "$error_file"
    exit_code="$?"
    set -e

    [[ "$exit_code" -eq 1 ]] \
        || fail_test "provider connectivity failure must exit 1, got $exit_code"
    assert_single_json_document "$result_file"
    jq -e '
        .status == "failed"
        and .error == {stage:"provider-connectivity",message:"Cannot reach configured Ollama endpoint"}
    ' "$result_file" >/dev/null \
        || fail_test "provider connectivity failure must use the safe contract message"
    if grep -Fq 'super-secret' "$result_file" "$error_file"; then
        fail_test "provider connectivity output exposed URL credentials"
    fi
}

create_origin() {
    /usr/bin/git init --bare "$TEST_ROOT/origin.git" >/dev/null
    /usr/bin/git init "$TEST_ROOT/seed" >/dev/null
    /usr/bin/git -C "$TEST_ROOT/seed" config user.name Test
    /usr/bin/git -C "$TEST_ROOT/seed" config user.email test@example.invalid
    printf 'initial\n' > "$TEST_ROOT/seed/README.md"
    /usr/bin/git -C "$TEST_ROOT/seed" add README.md
    /usr/bin/git -C "$TEST_ROOT/seed" commit -m initial >/dev/null
    /usr/bin/git -C "$TEST_ROOT/seed" branch -M main
    /usr/bin/git -C "$TEST_ROOT/seed" remote add origin "$TEST_ROOT/origin.git"
    /usr/bin/git -C "$TEST_ROOT/seed" push -u origin main >/dev/null
    TEST_ORIGIN="$TEST_ROOT/origin.git"
    export TEST_ORIGIN
}

write_command_mocks() {
    mkdir -p "$MOCK_BIN"

    cat > "$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_STAGE:-}" == "commit-config-name" \
    && "${1:-} ${2:-}" == "config user.name" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "commit-config-email" \
    && "${1:-} ${2:-}" == "config user.email" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "staging" && "${1:-} ${2:-}" == "add --all" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "commit" && "${1:-}" == "commit" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "commit-sha" \
    && "${1:-} ${2:-}" == "rev-parse HEAD" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "push" && "${1:-}" == "push" ]]; then
    exit 1
fi
if [[ "${FAIL_STAGE:-}" == "branch-query" && "${1:-}" == "ls-remote" ]]; then
    exit 128
fi
exec /usr/bin/git "$@"
EOF

    cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "auth status"|"auth setup-git")
        exit 0
        ;;
    "repo clone")
        exec /usr/bin/git clone "$TEST_ORIGIN" "$4"
        ;;
    "pr list")
        [[ "${CREATE_PR:-true}" == "false" ]] && exit 2
        [[ "${FAIL_STAGE:-}" == "pr-query" ]] && exit 1
        if [[ "${TEST_FORK_COLLISION:-false}" == "true" ]]; then
            while [[ $# -gt 0 && "$1" != "--jq" ]]; do shift; done
            [[ $# -eq 2 ]] || exit 2
            printf '%s\n' '[{"url":"https://github.com/owner/repository/pull/99","isCrossRepository":true},{"url":"https://github.com/owner/repository/pull/42","isCrossRepository":false}]' | jq -r "$2"
            exit
        fi
        printf '%s' "${TEST_EXISTING_PR:-}"
        ;;
    "pr create")
        [[ "${CREATE_PR:-true}" == "false" || -n "${TEST_EXISTING_PR:-}" ]] && exit 2
        [[ "${FAIL_STAGE:-}" == "pull-request" ]] && exit 1
        printf '%s\n' "https://github.com/owner/repository/pull/1"
        ;;
    *)
        printf 'unexpected gh command: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

    cat > "$MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    run)
        printf 'implemented\n' > implemented.txt
        if [[ "${CHANGE_MODE:-tracked-and-untracked}" != "untracked-only" ]]; then
            printf 'implemented\n' >> README.md
        fi
        printf '%s\n' '{"sessionID":"test-session"}'
        if [[ "${FAIL_STAGE:-}" == "implementation" ]]; then
            exit 7
        fi
        exit 0
        ;;
    export)
        printf '%s\n' '{"messages":[{"parts":[{"type":"step_finish","tokens":{"input":20,"output":10,"cache":{"read":5,"write":1}}}]}]}'
        ;;
    *)
        printf 'unexpected opencode command: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

    chmod +x "$MOCK_BIN/git" "$MOCK_BIN/gh" "$MOCK_BIN/opencode"
}

assert_lifecycle_result() {
    local result_file="$1"
    local expected_status="$2"
    local expected_stage="$3"
    local expected_branch="$4"
    local expected_commit_state="$5"
    local expected_pull_request="$6"
    local expected_message="$7"

    jq -e \
        --arg status "$expected_status" \
        --arg stage "$expected_stage" \
        --arg branch "$expected_branch" \
        --arg commitState "$expected_commit_state" \
        --arg pullRequest "$expected_pull_request" \
        --arg message "$expected_message" '
            .schemaVersion == 1
            and .status == $status
            and (if $status == "success" then .error == null else .error == {stage:$stage,message:$message} end)
            and (if $branch == "null" then .delivery.branch == null else .delivery.branch == $branch end)
            and (if $commitState == "null" then .delivery.commit == null else (.delivery.commit | type) == "string" and (.delivery.commit | length) > 0 end)
            and (if $pullRequest == "null" then .delivery.pullRequest == null else .delivery.pullRequest == $pullRequest end)
            and (.metrics.durationMs | type) == "number"
            and .metrics.peakContextTokens == 26
            and .metrics.inputTokens == 20
            and .metrics.outputTokens == 10
            and .metrics.llmRequests == 1
            and (has("taskId") or has("repository") or has("branch") or has("commit") or has("pullRequest") or has("model") or has("contextLimitTokens") or has("stage") | not)
        ' "$result_file" >/dev/null \
        || fail_test "entrypoint result did not preserve the expected $expected_stage lifecycle state"
}

run_lifecycle_case() {
    local case_name="$1"
    local failure_stage="$2"
    local expected_status="$3"
    local expected_stage="$4"
    local expected_branch="$5"
    local expected_commit_state="$6"
    local expected_pull_request="$7"
    local expected_message="$8"
    local change_mode="${9:-tracked-and-untracked}"
    local result_file="$TEST_ROOT/$case_name.json"
    local error_file="$TEST_ROOT/$case_name.log"
    local exit_code

    set +e
    env \
        PATH="$MOCK_BIN:$PATH" \
        TEST_ORIGIN="$TEST_ORIGIN" \
        FAIL_STAGE="$failure_stage" \
        CHANGE_MODE="$change_mode" \
        SDLC_WORK_ROOT="$TEST_ROOT/work-$case_name" \
        SDLC_OPENCODE_TEMPLATE="$SERVICE_DIR/opencode.json.template" \
        REPO="owner/repository" \
        TASK_ID="AIEXEC-$case_name" \
        TASK="$TEST_TASK" \
        GH_TOKEN="test-token" \
        MODEL="openai/test-model" \
        OPENAI_API_KEY="test-key" \
        "$SERVICE_DIR/entrypoint.sh" implement \
        > "$result_file" 2> "$error_file"
    exit_code="$?"
    set -e

    if [[ "$expected_status" == "success" ]]; then
        [[ "$exit_code" -eq 0 ]] \
            || fail_test "$case_name must exit 0, got $exit_code"
    else
        [[ "$exit_code" -eq 1 ]] \
            || fail_test "$case_name must exit 1, got $exit_code"
    fi

    assert_single_json_document "$result_file"
    validate_result_schema "$result_file"
    assert_lifecycle_result \
        "$result_file" \
        "$expected_status" \
        "$expected_stage" \
        "$expected_branch" \
        "$expected_commit_state" \
        "$expected_pull_request" \
        "$expected_message"

    [[ -s "$error_file" ]] \
        || fail_test "$case_name must write operational diagnostics to stderr"
    if grep -Fq -e 'test-key' -e 'test-token' -e "$TEST_TASK" "$error_file"; then
        fail_test "$case_name stderr exposed credentials or task text"
    fi
}

assert_entrypoint_owns_success_exit
run_unsupported_command_test
run_credential_url_failure_test
create_origin
write_command_mocks

run_lifecycle_case implementation implementation failed implementation null null null "OpenCode exited with code 7"
run_lifecycle_case commit-config-name commit-config-name failed commit null null null "Failed to configure Git user name"
run_lifecycle_case commit-config-email commit-config-email failed commit null null null "Failed to configure Git user email"
run_lifecycle_case staging staging failed commit null null null "Failed to stage repository changes"
run_lifecycle_case commit commit failed commit null null null "Git commit failed"
run_lifecycle_case commit-sha commit-sha failed commit null null null "Failed to resolve commit SHA"
run_lifecycle_case push push failed push null string null "Git push failed"
run_lifecycle_case pull-request pull-request failed pull-request ai/AIEXEC-pull-request string null "Failed to create pull request"
run_lifecycle_case success '' success '' ai/AIEXEC-success string https://github.com/owner/repository/pull/1 ''
run_lifecycle_case untracked-only '' success '' ai/AIEXEC-untracked-only string https://github.com/owner/repository/pull/1 '' untracked-only

# Repeated runs must preserve the previous remote tip and add a new commit.
BRANCH=feature/reused CREATE_PR=false run_lifecycle_case new-no-pr '' success '' feature/reused string null ''
previous_tip="$(/usr/bin/git --git-dir="$TEST_ORIGIN" rev-parse refs/heads/feature/reused)"
BRANCH=feature/reused CREATE_PR=false run_lifecycle_case existing-no-pr '' success '' feature/reused string null ''
new_tip="$(/usr/bin/git --git-dir="$TEST_ORIGIN" rev-parse refs/heads/feature/reused)"
[[ "$previous_tip" != "$new_tip" ]] || fail_test 'existing branch must receive a new commit'
[[ "$(/usr/bin/git --git-dir="$TEST_ORIGIN" rev-parse "$new_tip^")" == "$previous_tip" ]] \
    || fail_test 'existing branch history must be preserved'
BRANCH=feature/reused CREATE_PR=true run_lifecycle_case existing-create-pr '' success '' feature/reused string https://github.com/owner/repository/pull/1 ''
BRANCH=feature/reused CREATE_PR=true TEST_EXISTING_PR=https://github.com/owner/repository/pull/42 \
    run_lifecycle_case existing-pr '' success '' feature/reused string https://github.com/owner/repository/pull/42 ''
BRANCH=feature/reused CREATE_PR=true TEST_FORK_COLLISION=true \
    run_lifecycle_case fork-collision '' success '' feature/reused string https://github.com/owner/repository/pull/42 ''
run_lifecycle_case pr-query pr-query failed pull-request ai/AIEXEC-pr-query string null 'Failed to check existing pull requests'

# Early failures must stop before OpenCode or any delivery operation.
for scenario in invalid-flag branch-query; do
    result_file="$TEST_ROOT/$scenario.json"
    flag=true
    [[ "$scenario" == invalid-flag ]] && flag=maybe
    if env PATH="$MOCK_BIN:$PATH" TEST_ORIGIN="$TEST_ORIGIN" FAIL_STAGE="$scenario" \
        CREATE_PR="$flag" REPO=owner/repository TASK_ID="$scenario" TASK="$TEST_TASK" \
        GH_TOKEN=test-token MODEL=openai/test-model OPENAI_API_KEY=test-key \
        SDLC_WORK_ROOT="$TEST_ROOT/work-$scenario" \
        SDLC_OPENCODE_TEMPLATE="$SERVICE_DIR/opencode.json.template" \
        "$SERVICE_DIR/entrypoint.sh" implement > "$result_file" 2> "$TEST_ROOT/$scenario.log"; then
        fail_test "$scenario must fail"
    fi
    stage=implementation-branch
    [[ "$scenario" == invalid-flag ]] && stage=configuration
    validate_result_schema "$result_file"
    jq -e --arg stage "$stage" '.status == "failed" and .error.stage == $stage and .delivery == {branch:null,commit:null,pullRequest:null}' "$result_file" >/dev/null
    [[ ! -e "$TEST_ROOT/work-$scenario/repo/implemented.txt" ]] || fail_test "$scenario ran OpenCode"
done

printf 'PASS: entrypoint lifecycle tests\n'
