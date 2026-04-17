# Sub-Agent Playbook: PR Reviewer — Quality-Gates Acceptance Criteria

## Purpose

Review a pull-request diff that enables quality gates on a consumer JVM repository.
Emit either `GO` (the PR is ready to merge) or `CHANGE_REQUEST` (with a numbered list
of specific items that must be fixed before re-review).

---

## Inputs

- Pull-request diff (provided by the orchestrator via `gh pr diff <number>` or equivalent)
- Repo metadata: `{{JAVA_VERSION}}`, `{{FLOW_TYPE}}`, `{{COVERAGE_ENABLED}}`, `{{REPO_NAME}}`, `{{FT_EXCLUSIONS}}`, `{{LANGUAGES}}`

---

## Checklist

Work through each item in order.  Mark it **PASS** or **FAIL**.  
If any item is **FAIL**, the overall verdict is `CHANGE_REQUEST`.

### W1 — `merge-gate.yml` has `on: pull_request` trigger

- The file must exist at `.github/workflows/merge-gate.yml`.
- The `on:` block must contain a `pull_request:` key targeting `main` (or the repo's default branch).
- **FAIL** if the file is absent or the trigger is missing.

### W2 — `merge-gate.yml` contains a `gate-merge` job named `gate/merge`

- A job with key `gate-merge` (or equivalent) must exist.
- That job must have `name: gate/merge` exactly.
- The job must have `if: always()` so it runs even when upstream jobs fail.
- The job must declare `needs:` covering at least the `build` and `security` jobs.
- **FAIL** if any of the above is missing.

### W3 — `quality.yml` does NOT have `pull_request:` trigger

- The file must exist at `.github/workflows/quality.yml`.
- The `on:` block must **not** contain `pull_request:`.
- Acceptable triggers: `push`, `workflow_dispatch`, `workflow_call`.
- **FAIL** if `pull_request:` appears anywhere in the `on:` block.

### W4 — `security.yml` does NOT have `pull_request:` trigger

- Same rule as W3 but for `.github/workflows/security.yml`.
- **FAIL** if `pull_request:` appears anywhere in the `on:` block.

### W5 — Convention plugin is applied

- `build.gradle.kts` (root) must contain `id("org.octopusden.octopus-quality")` inside the `plugins {}` block.
- **FAIL** if the plugin ID is absent.

### W6 — Action refs use immutable pinning (tag or SHA), not mutable branch refs

- Every `uses:` referencing `octopusden/octopus-base` must end with either:
  - a semver tag (e.g. `@v2.0.3`), or
  - a full commit SHA (e.g. `@abc123def456...`).
- Mutable branch refs `@main`, `@master`, and `@HEAD` are **not** acceptable because they resolve to a moving target.
- **FAIL** if any such ref uses a mutable branch pointer.

### W7 — `java-version` matches the repo's CI runtime JDK

- Every `actions/setup-java` step across all three new workflow files must specify the same `java-version`
  that was already used by the repo's existing CI workflows (or the value supplied by the orchestrator).
- **FAIL** if the version differs or is absent.

### W8 — Baselines committed (Kotlin repos only)

- If `{{LANGUAGES}}` contains `kotlin`, the diff must include:
  - At least one `detekt-baseline.xml` file
  - At least one baseline file produced by `ktlintGenerateBaseline`
- **FAIL** if baselines are absent for a Kotlin repo.
- **SKIP** this check for Java / Groovy repos.

### W9 — No secrets or credentials in the diff

- Scan the diff for patterns that suggest credentials: API keys, tokens, passwords, private keys, `.env` content.
- Use heuristics: strings matching `ghp_`, `-----BEGIN`, `password=`, `secret=`, `token=` (case-insensitive).
- **FAIL** if any match is found; escalate to a human immediately.

### W10 — Coverage settings match repo state

- If `{{COVERAGE_ENABLED}}` is `true`, `build.gradle.kts` must contain an `octopusQuality { coverage { … } }` block
  with `minimumLineCoverage.set(…)` and/or `overallMinimum.set(…)` using `java.math.BigDecimal`.
- The `overallMinimum` threshold must be current measured coverage + 5 % (±1 pp tolerance).
- If `{{COVERAGE_ENABLED}}` is `false`, the block must contain `coverage { enabled.set(false) }`.
- **FAIL** if the configuration contradicts the expected state.

---

## Output Format

Emit one of the following verdicts, followed by details.

### GO

```
GO

All acceptance criteria passed.
PR is ready to merge.
```

### CHANGE_REQUEST

```
CHANGE_REQUEST

The following items must be fixed before this PR can be merged:

1. [W2] gate-merge job is missing `if: always()`.
2. [W6] Action ref `octopusden/octopus-base/.github/actions/merge-gate@main` must use a semver tag.
3. [W8] No detekt-baseline.xml found; run `./gradlew detektBaseline` and commit the result.
```

List only failing items.  Be specific: quote the offending line or file path where possible.
