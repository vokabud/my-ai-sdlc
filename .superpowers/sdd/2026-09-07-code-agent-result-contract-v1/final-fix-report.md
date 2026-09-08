# Code-Agent Result Contract v1: final fix report

Date: 2026-09-07
Worktree: `G:/Solutions/my-ai-sdlc/.worktrees/result-contract-v1`
Base: `3b26493`
Implementation commit: `78cf349` (`fix: complete code-agent result contract v1`)

## Outcome

All Important and Minor findings in `final-fix-brief.md` were addressed in one fix wave.

- The no-change gate now includes `git ls-files --others --exclude-standard`, so an implementation that creates only untracked files reaches commit and delivery.
- Both Git identity settings, staging, commit creation, and commit SHA resolution now emit deterministic `commit`-stage failures. Delivery remains `{branch:null,commit:null,pullRequest:null}` for each failure.
- `AGENTS.md` now points to `result.schema.json` as the authoritative contract and shows concise nested v1 success/failure examples.
- Every conditional schema fragment that uses `properties` now declares `type: "object"`; valid-fixture validation is asserted to produce no stderr warnings.
- `ajv-cli` remains pinned to `5.0.0`; `package.json` and `package-lock.json` were not changed.

## Files changed

- `src/services/code-agent/entrypoint.sh`
- `src/services/code-agent/tests/entrypoint-lifecycle.test.sh`
- `src/services/code-agent/result.schema.json`
- `src/services/code-agent/tests/result-schema.test.sh`
- `src/services/code-agent/AGENTS.md`
- `.superpowers/sdd/2026-09-07-code-agent-result-contract-v1/final-fix-report.md`

## TDD evidence: Important finding 1

The regression case sets `CHANGE_MODE=untracked-only`. The OpenCode mock creates `implemented.txt` and deliberately does not modify seeded `README.md`. Removing the new untracked predicate makes this case fail.

The Windows `bash.exe` entry point was unavailable (`Bash/Service/CreateInstance/E_ACCESSDENIED`), so Linux checks ran in the existing worker image from a read-only mount. A temporary container copy had CRLF removed from shell files to compensate for the Windows checkout; repository files were not rewritten by this harness step.

RED command:

```powershell
podman run --rm --entrypoint bash --volume 'G:\Solutions\my-ai-sdlc\.worktrees\result-contract-v1:/src:ro' localhost/my-sdlc-agent:0.4 -c "cp -a /src /tmp/repo && find /tmp/repo/src/services/code-agent -type f -name '*.sh' -exec sed -i 's/\r$//' '{}' + && cd /tmp/repo/src/services/code-agent && tests/entrypoint-lifecycle.test.sh"
```

Observed exit and terminal failure line:

```text
exit 1
FAIL: untracked-only must exit 0, got 1
```

AJV also printed the already-recorded `strictTypes` warnings during this run; those were addressed separately below.

GREEN command: the same command after adding the `git ls-files --others --exclude-standard` predicate.

Observed result:

```text
exit 0
PASS: entrypoint lifecycle tests
```

## TDD evidence: Important finding 2

The lifecycle Git mock now has independent failure modes for `config user.name`, `config user.email`, `add --all`, `commit`, and `rev-parse HEAD`. The result assertion checks the exact deterministic error object and null delivery artifacts.

RED command:

```powershell
podman run --rm --entrypoint bash --volume 'G:\Solutions\my-ai-sdlc\.worktrees\result-contract-v1:/src:ro' localhost/my-sdlc-agent:0.4 -c "cp -a /src /tmp/repo && find /tmp/repo/src/services/code-agent -type f -name '*.sh' -exec sed -i 's/\r$//' '{}' + && cd /tmp/repo/src/services/code-agent && tests/entrypoint-lifecycle.test.sh"
```

Observed exit and terminal failure line (the first new case was `commit-config-name`; the old global trap emitted `worker`):

```text
exit 1
FAIL: entrypoint result did not preserve the expected commit lifecycle state
```

GREEN command: the same command after guarding all five commands with `fail "commit" ...`.

Observed result:

```text
exit 0
PASS: entrypoint lifecycle tests
```

The tested deterministic messages are:

```text
Failed to configure Git user name
Failed to configure Git user email
Failed to stage repository changes
Git commit failed
Failed to resolve commit SHA
```

## TDD evidence: schema warnings

The schema test first captured stderr from both valid fixtures and failed if the capture was non-empty.

RED command:

```powershell
podman run --rm --entrypoint bash --volume 'G:\Solutions\my-ai-sdlc\.worktrees\result-contract-v1:/src:ro' localhost/my-sdlc-agent:0.4 -c "cp -a /src /tmp/repo && find /tmp/repo/src/services/code-agent -type f -name '*.sh' -exec sed -i 's/\r$//' '{}' + && cd /tmp/repo/src/services/code-agent && tests/result-schema.test.sh"
```

Observed exit and warning paths:

```text
exit 1
FAIL: valid schema fixtures produced validation warnings
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/0/then/properties/task" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/0/then/properties/execution" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/0/then/properties/delivery" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/0/then/properties/metrics" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/1/if/properties/delivery" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/1/then/properties/delivery" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/2/if/properties/delivery" (strictTypes)
strict mode: missing type "object" for keyword "properties" at "https://schemas.local/sdlc/code-agent-result-v1.json#/allOf/2/then/properties/delivery" (strictTypes)
```

GREEN command: the same command after adding explicit object types.

```text
exit 0
PASS: result schema tests
```

Existing negative fixtures still reject a missing required section, an undocumented stage, and a pushed branch without a commit.

## Complete Linux suite

Exact command (the prefix creates a disposable Linux copy and normalizes only its shell-file line endings):

```powershell
podman run --rm --entrypoint bash --volume 'G:\Solutions\my-ai-sdlc\.worktrees\result-contract-v1:/src:ro' localhost/my-sdlc-agent:0.4 -c "cp -a /src /tmp/repo && find /tmp/repo/src/services/code-agent -type f -name '*.sh' -exec sed -i 's/\r$//' '{}' + && cd /tmp/repo/src/services/code-agent && npm ci && bash -n entrypoint.sh lib/context-limit.sh lib/metrics.sh lib/result.sh tests/*.sh && bash tests/result-schema.test.sh && bash tests/result-contract.test.sh && bash tests/context-limit.test.sh && bash tests/metrics.test.sh && bash tests/entrypoint-context-limit.test.sh && bash tests/entrypoint-lifecycle.test.sh"
```

Observed output (standard Git `init.defaultBranch` hint paragraphs omitted; exit and substantive lines are verbatim):

```text
exit 0
npm warn deprecated inflight@1.0.6: This module is not supported, and leaks memory. Do not use it. Check out lru-cache if you want a good and tested way to coalesce async requests by a key value, which is much more comprehensive and powerful.
npm warn deprecated glob@7.2.3: Old versions of glob are not supported, and contain widely publicized security vulnerabilities, which have been fixed in the current version. Please update. Support for old versions may be purchased (at exorbitant rates) by contacting i@izs.me

added 26 packages, and audited 27 packages in 986ms

4 packages are looking for funding
  run `npm fund` for details

2 high severity vulnerabilities

To address all issues (including breaking changes), run:
  npm audit fix --force

Run `npm audit` for details.
PASS: result schema tests
PASS: result contract tests
PASS: context-limit tests
PASS: metrics tests
PASS: entrypoint context-limit tests
To /tmp/tmp.HNp0dJPHUN/origin.git
 * [new branch]      main -> main
PASS: entrypoint lifecycle tests
```

The silent `bash -n` step exited zero before the six scripts ran.

## Container image verification

Build command:

```powershell
podman build -f dockerfile -t localhost/my-sdlc-agent:0.4 .
```

Observed result:

```text
exit 0
STEP 16/19: RUN bash -c 'source /opt/sdlc/lib/result.sh ...'
STEP 18/19: RUN dotnet --list-sdks ... && opencode --version
8.0.424 [/usr/share/dotnet/sdk]
10.0.400 [/usr/share/dotnet/sdk]
v22.23.2
10.9.8
git version 2.43.0
gh version 2.97.0 (2026-07-31)
ripgrep 14.1.0
1.18.21
COMMIT localhost/my-sdlc-agent:0.4
Successfully tagged localhost/my-sdlc-agent:0.4
ea51a9ecf1c0a6dba3662942f06a9e9df00f7b68b8bcec00baeed02dcb22458d
```

Inspection command:

```powershell
podman run --rm --entrypoint bash localhost/my-sdlc-agent:0.4 -c 'dotnet --list-sdks && dotnet --list-runtimes && node --version && git --version && gh --version && rg --version && jq --version && opencode --version && bash -n /usr/local/bin/sdlc-agent /opt/sdlc/lib/*.sh'
```

Observed output:

```text
exit 0
8.0.424 [/usr/share/dotnet/sdk]
10.0.400 [/usr/share/dotnet/sdk]
Microsoft.AspNetCore.App 8.0.30 [/usr/share/dotnet/shared/Microsoft.AspNetCore.App]
Microsoft.AspNetCore.App 10.0.11 [/usr/share/dotnet/shared/Microsoft.AspNetCore.App]
Microsoft.NETCore.App 8.0.30 [/usr/share/dotnet/shared/Microsoft.NETCore.App]
Microsoft.NETCore.App 10.0.11 [/usr/share/dotnet/shared/Microsoft.NETCore.App]
v22.23.2
git version 2.43.0
gh version 2.97.0 (2026-07-31)
https://github.com/cli/cli/releases/tag/v2.97.0
ripgrep 14.1.0
features:-simd-accel,+pcre2
simd(compile):+SSE2,-SSSE3,-AVX2
simd(runtime):+SSE2,+SSSE3,+AVX2
PCRE2 10.42 is available (JIT is available)
jq-1.7
1.18.21
```

The final `bash -n` was silent and the container exited zero.

## Dependency audit and remaining concern

`ajv-cli` is still exactly `5.0.0` in both manifests. No dependency file changed.

Command:

```powershell
podman run --rm --entrypoint bash --volume 'G:\Solutions\my-ai-sdlc\.worktrees\result-contract-v1:/src:ro' --workdir /src/src/services/code-agent localhost/my-sdlc-agent:0.4 -c "npm audit --json"
```

Observed audit result:

```text
exit 1
auditReportVersion: 2
high: 2; total: 2
ajv-cli (direct, severity high) via fast-json-patch
fast-json-patch <3.1.1 (transitive, severity high)
advisory: GHSA-8gh8-hqwg-xf34, prototype pollution, CVSS 7.3
fixAvailable: ajv-cli 0.6.0, semver-major
dependencies: prod 1, dev 26, total 26
```

Remaining development-tooling concern: the plan-pinned `ajv-cli@5.0.0` tree emits deprecation warnings for `inflight@1.0.6` and `glob@7.2.3`, and npm reports two high-severity audit entries through `fast-json-patch`. The available automatic remediation proposes a semver-major downgrade to `ajv-cli@0.6.0`, so this fix wave intentionally does not apply it. These packages are contract-test development tooling and are not copied into the production worker image.

## Self-review

Commands:

```powershell
git diff --check
git status --short
git diff --name-only
git diff --exit-code -- src/services/code-agent/package.json src/services/code-agent/package-lock.json
git diff --cached --check
```

Observed results before commit:

```text
git diff --check: exit 0, no whitespace errors
git diff --exit-code -- package.json package-lock.json: exit 0, no dependency changes
git diff --cached --check: exit 0, no whitespace errors
status/name-only: exactly the five implementation files listed above
```

Review conclusions:

- The untracked success case does not alter the seeded tracked file and verifies full commit, push, and pull-request delivery.
- Each commit-preparation mock targets one exact Git command. Every failure asserts `status == "failed"`, the exact `error` object, and all-null delivery artifacts.
- Commit state is recorded only after `rev-parse HEAD` succeeds, so SHA-resolution failure cannot leak a delivery artifact.
- Schema changes add types only where parent sections are already required objects, preserving accepted/rejected document semantics.
- The valid-fixture stderr assertion would fail if any current `strictTypes` warning returns.
- Contract documentation now matches the nested v1 shape and delegates the exhaustive enum/rules to the schema.
- No unrelated files or dependency versions changed.

No product-code concerns remain from the final findings list. The pinned AJV development-tooling audit/deprecation issue above remains intentionally open.
