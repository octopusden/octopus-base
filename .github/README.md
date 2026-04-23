# .github — Public/Internal Workflow Contract

This document defines which workflows and composite actions in this repository
are part of the **public API** (callable by consumer repos) and which are
**internal** (used only within octopus-base itself).

---

## Public reusable workflows

**Location:** `.github/workflows/common-*.yml`

All files matching `common-*.yml` are public reusable workflows.  They expose
`on: workflow_call:` and are meant to be called by consumer repositories via:

```yaml
uses: octopusden/octopus-base/.github/workflows/common-<name>.yml@<ref>
```

**Current public workflows:**

| File | Purpose |
|---|---|
| `common-check-and-register-release.yml` | Check and register a release |
| `common-docker-build-deploy.yml` | Docker image build and deploy |
| `common-java-gradle-build.yml` | Java/Gradle build |
| `common-java-gradle-quality-gates.yml` | Java/Gradle quality gates |
| `common-java-gradle-release.yml` | Java/Gradle release |
| `common-java-gradle-security-reports.yml` | Java/Gradle security reports |
| `common-java-maven-build.yml` | Java/Maven build |
| `common-java-maven-release.yml` | Java/Maven release |
| `common-py-2-3-build-deploy.yml` | Python 2/3 build and deploy |
| `common-py-build-deploy.yml` | Python build and deploy |
| `common-py3-pysvn-build-deploy.yml` | Python 3 / pysvn build and deploy |
| `common-register-release.yml` | Register a release |

### Rules for public reusable workflows

- MUST contain `workflow_call` in their `on:` triggers.
- MUST NOT reference `.github/actions/internal/` paths (reserved for internal
  use only).
- MUST NOT call internal workflows (i.e., workflows without `workflow_call`).

---

## Internal workflows

**Location:** `.github/workflows/` — any file that does **not** match
`common-*.yml`

These workflows are triggered by events within octopus-base only (push, pull
request, schedule, etc.) and are **not** intended to be reused by consumers.

**Current internal workflows:**

| File | Purpose |
|---|---|
| `check-octopus-test-consumer.yml` | CI checks run against the octopus-test-consumer repo |
| `release-octopus-base.yml` | Releases octopus-base itself |
| `test-merge-gate-action.yml` | Synthetic smoke test for the `merge-gate` composite action |
| `verify-octopus-test-consumer.yml` | Verifies the octopus-test-consumer integration (see note below) |

### Internal workflows that expose `workflow_call`

Some internal workflows declare `on: workflow_call:` for **local composition**
only — they are called by other workflows in this repository but are still
internal and MUST NOT be called by external consumer repositories.

| File | Called by | Reason for `workflow_call` |
|---|---|---|
| `verify-octopus-test-consumer.yml` | `check-octopus-test-consumer.yml` | Allows the check workflow to reuse the verification logic as a named job |

**Key distinction:**

- `common-*.yml` — **public API**: stable contract, versioned, callable by any
  consumer repository.
- Non-`common-*` workflows with `workflow_call` — **internal composition**:
  `workflow_call` is an implementation detail for local orchestration only.
  Calling them from outside octopus-base is unsupported and may break without
  notice.

---

## Public composite actions

**Location:** `.github/actions/<name>/action.yml`

Composite actions placed directly under `.github/actions/` are public and may
be referenced by consumer repos:

```yaml
uses: octopusden/octopus-base/.github/actions/<name>@<ref>
```

**Current public composite actions:**

| Directory | Purpose |
|---|---|
| `get-version/` | Resolve the project version from Gradle or Maven |
| `merge-gate/` | Aggregate upstream job results; fails unless every job reports "success" |

---

## Internal composite actions

**Location:** `.github/actions/internal/<name>/action.yml`

The `internal/` sub-namespace is reserved for composite actions that are
implementation details of public workflows and MUST NOT be called directly by
consumers.  None exist today; the namespace is reserved to keep the public
surface clean.

---

## Security rules for workflows

### Rule: no direct expression interpolation in `run:` blocks

Interpolating `${{ inputs.* }}` or user-controlled `${{ github.event.* }}`
expressions directly inside a `run:` shell block is a **shell injection vector**
(CVE class: GitHub Actions script injection).  An attacker who can supply the
input or trigger the event can execute arbitrary shell code.

**Dangerous pattern (do not use):**

```yaml
- name: Apply skipped tasks
  run: |
    IFS=',' read -r -a tasks <<< "${{ inputs.skip-extra-tasks }}"
```

**Safe pattern — assign to `env:`, reference as `$VAR` in `run:`:**

```yaml
- name: Apply skipped tasks
  env:
    SKIP_EXTRA_TASKS: ${{ inputs.skip-extra-tasks }}
  run: |
    IFS=',' read -r -a tasks <<< "$SKIP_EXTRA_TASKS"
```

The lint script `validate-workflow-injection.sh` enforces this rule in CI
(added in issue #100, triggered by a CodeRabbit finding in PR #99).

Specifically flagged expression patterns:
- `${{ inputs.* }}` — caller-supplied strings
- `${{ github.event.pull_request.title }}` / `.body` / `.head.ref`
- `${{ github.event.issue.title }}` / `.body`
- `${{ github.event.comment.body }}`
- `${{ github.head_ref }}`

**Escape hatch:** if a pattern is provably safe, add a `relative/path:lineno`
entry to `.github/scripts/workflow-injection-whitelist.txt` with a comment
explaining why it is safe.

---

## Adding a new reusable workflow

1. Create `.github/workflows/common-<name>.yml`.
2. Ensure `on:` includes `workflow_call:` (with all required/optional inputs
   and secrets declared).
3. Do not reference `.github/actions/internal/` from this file.
4. Update the table in this README.
5. The automated lint (`validate-workflow-naming.sh`) will enforce rules 2–3
   in CI.
6. Do not interpolate `${{ inputs.* }}` directly in `run:` blocks — see the
   security rule above.

## Adding a new composite action

- **Public:** create `.github/actions/<name>/action.yml` and add it to the
  table above.
- **Internal:** create `.github/actions/internal/<name>/action.yml`.  Add a
  comment in the file header stating it is internal-only.
