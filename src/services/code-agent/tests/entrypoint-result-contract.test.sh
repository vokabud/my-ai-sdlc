#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_single_json_document() {
    local result_file="$1"

    [[ "$(jq -s 'length' "$result_file")" == "1" ]] \
        || fail_test "entrypoint must emit exactly one JSON document"
    jq -e . "$result_file" >/dev/null \
        || fail_test "entrypoint result must be valid JSON"
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
    jq -e '
        .status == "failed"
        and .error == {stage:"configuration",message:"Unsupported command; expected '\''implement'\''"}
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

write_success_fakes() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"

    cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-} ${2:-}" in
    "auth status"|"auth setup-git")
        exit 0
        ;;
    "repo clone")
        mkdir -p "$4/.git/info"
        exit 0
        ;;
    "pr create")
        printf '%s\n' 'https://github.com/owner/repository/pull/42'
        exit 0
        ;;
esac

exit 1
EOF

    cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-}" in
    ls-remote)
        exit 1
        ;;
    diff)
        if [[ " ${*} " == *" --quiet "* ]]; then
            exit 1
        fi
        exit 0
        ;;
    rev-parse)
        printf '%s\n' 'abc123'
        exit 0
        ;;
    fetch|checkout|reset|status|config|add|commit|push)
        exit 0
        ;;
esac

exit 1
EOF

    cat > "$fake_bin/opencode" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-}" in
    run)
        printf '%s\n' '{"sessionID":"session-test"}'
        ;;
    export)
        printf '%s\n' '{"messages":[{"parts":[{"type":"step_finish","tokens":{"input":10,"output":2,"cache":{"read":3,"write":1}}}]}]}'
        ;;
    *)
        exit 1
        ;;
esac
EOF

    chmod +x "$fake_bin/gh" "$fake_bin/git" "$fake_bin/opencode"
}

run_success_exit_test() {
    local harness_dir="$TEST_ROOT/success-service"
    local fake_bin="$TEST_ROOT/success-bin"
    local work_root="$TEST_ROOT/work"
    local template_file="$TEST_ROOT/opencode.json.template"
    local result_file="$TEST_ROOT/success.json"
    local error_file="$TEST_ROOT/success.log"
    local exit_code

    mkdir -p "$harness_dir"
    cp "$SERVICE_DIR/entrypoint.sh" "$harness_dir/entrypoint.sh"
    cp -R "$SERVICE_DIR/lib" "$harness_dir/lib"
    sed -i \
        -e "s|^WORK_ROOT=.*|WORK_ROOT=\"$work_root\"|" \
        -e "s|/opt/sdlc/opencode.json.template|$template_file|" \
        "$harness_dir/entrypoint.sh"
    printf '%s\n' '{}' > "$template_file"
    write_success_fakes "$fake_bin"

    set +e
    PATH="$fake_bin:$PATH" \
    REPO="owner/repository" \
    TASK_ID="success-test" \
    TASK="Test task" \
    GH_TOKEN="test-token" \
    MODEL="openai/test-model" \
    OPENAI_API_KEY="test-api-key" \
        "$harness_dir/entrypoint.sh" implement \
        > "$result_file" \
        2> "$error_file"
    exit_code="$?"
    set -e

    [[ "$exit_code" -eq 0 ]] \
        || fail_test "successful entrypoint must explicitly exit 0, got $exit_code"
    assert_single_json_document "$result_file"
    jq -e '
        .status == "success"
        and .delivery == {
            branch:"ai/success-test",
            commit:"abc123",
            pullRequest:"https://github.com/owner/repository/pull/42"
        }
        and .error == null
    ' "$result_file" >/dev/null \
        || fail_test "successful entrypoint must emit the completed result contract"
}

assert_entrypoint_owns_success_exit
run_unsupported_command_test
run_credential_url_failure_test
run_success_exit_test

printf 'PASS: entrypoint result contract tests\n'
