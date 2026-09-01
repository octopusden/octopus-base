## GitHub Action

### Setup a workflow trigger
    
For release:
```yaml
on:
  repository_dispatch:
    types: [ release ]
```
More [information about triggers](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow)

The workflow can be triggered by REST API. The data payload has format:
```yaml
event_type:
  type: string
  enum:
    - release
client_payload:
  type: object
  properties:
    commit:
      type: string
    project_version:
      type: string
      pattern: ^([0-9]+)\.([0-9]+)\.([0-9]+)$
```

`project_version` carries **no** leading `v`: the release prepends one to build the tag, so a
`v`-prefixed payload produces the tag `vv2.0.1`. Three components are also not optional in
practice — a version like `2.0` publishes and tags but fails at registration, which requires
strict `X.Y.Z`.

## Calling the shared release workflow

A consumer does not write the release steps. It calls the reusable workflow, and checkout, build,
signing, publication and tagging all happen inside it. **Registration is the exception**: with the
defaults it does *not* run here — `register-release-immediately` is `false`, so the release log
entry is made by a second, separate caller shown below. Setting that input to `true` moves
registration into this run instead. A complete release caller is about fifteen lines:

```yaml
name: Gradle Release

on:
  repository_dispatch:
    types: [ release ]

jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-release.yml@v2.7.1
    with:
      flow-type: hybrid
      java-version: '11'
      commit-hash: ${{ github.event.client_payload.commit }}
      build-version: ${{ github.event.client_payload.project_version }}
    secrets: inherit
```

Two things about the calling job are easy to get wrong:

- **Do not set `runs-on:`.** The runner and the `Prod` environment are set inside the reusable
  workflow. Declaring `environment:` in the caller adds a second approval gate.
- **`secrets: inherit` is required — on whichever caller registers.** `OCTOPUS_GITHUB_TOKEN`
  reaches the registration step only through it, and nothing at the contract level will tell you
  if it is missing. With the defaults that caller is the `workflow_run` one below, so both need
  it: this one for Sonatype and GPG, that one for the registration token.

Registration is a separate caller, triggered by the release workflow finishing:

```yaml
name: Check for artifact and register release

on:
  workflow_run:
    workflows: ["Gradle Release"]
    types:
      - completed

jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-check-and-register-release.yml@v2.7.1
    if: "${{ github.event.workflow_run.conclusion == 'success' }}"
    with:
      artifact-pattern: "octopus/octopus-external-systems-clients/jira-client/_VER_/jira-client-_VER_.jar"
    secrets: inherit
```

`artifact-pattern` is relative to `https://repo1.maven.org/maven2/org/octopusden`, with `_VER_`
as the version placeholder. Point it at a module that is actually published.

Always pin to a released tag, never `@main`.

## Version calculation, publication, tagging

All of it is inside the reusable workflow — the version bump, the Sonatype upload, the Central
Portal publication, the tag and the GitHub Release. A consumer configures it with inputs and
never writes these steps.

What runs, in what order, with what deadlines, and what state each kind of failure leaves behind
is described in [Octopus Release Pipeline](Octopus%20Release%20Pipeline.md).

## Examples

- [Release workflow (non-docker)](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/release.yml)
- [Release workflow (with docker)](https://github.com/octopusden/octopus-employee-service/blob/main/.github/workflows/release.yml)
- [Build workflow](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/build.yml)
- [Registration workflow](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/check-and-register.yml)

## Reusable Quality and Security Gates (Gradle)

Use reusable workflows from `octopus-base` to avoid copy-paste between repositories.

Pin reusable workflow references to a released tag (for example `@v2.7.1`), not `@main`.
This protects consumer repositories from unreviewed breaking changes.

### Quality gates workflow

Reusable workflow: `.github/workflows/common-java-gradle-quality-gates.yml`

It provides:
- `quality/wrapper-validation`
- `quality/static`
- `quality/tests-coverage`

Consumer workflow example:

```yaml
name: Quality Gates

on:
  pull_request:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  quality:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-quality-gates.yml@<octopus-base-tag>
    with:
      java-version: "21"
      static-command: ./gradlew qualityStatic --no-daemon --stacktrace
      coverage-command: ./gradlew qualityCoverage --no-daemon --stacktrace
```

### Security reports workflow

Reusable workflow: `.github/workflows/common-java-gradle-security-reports.yml`

It provides:
- `security/codeql`
- `security/trivy`
- `security/dependency-check` (report-only, optional)

Consumer workflow example:

```yaml
name: Security Reports

on:
  pull_request:
  push:
    branches: [ main ]
  schedule:
    - cron: "0 3 * * *"
  workflow_dispatch:

jobs:
  security:
    permissions:
      security-events: write
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-security-reports.yml@<octopus-base-tag>
    with:
      java-version: "21"
      enable-dependency-check: false
      dependency-check-command: ./gradlew securityReport --no-daemon --stacktrace
```

### Gradle prerequisites in consumer repository

- `qualityStatic` task for static checks
- `qualityCoverage` task for tests + coverage
- `securityReport` task for dependency-check report (if dependency-check is enabled)

For mixed JVM repositories (`Java` + `Kotlin` + `Groovy`), keep these tasks language-agnostic and aggregate all enabled tools (for example `checkstyle`/`pmd`/`codenarc`/`detekt`/`ktlint`, plus `spotbugs` on modules that have Java and no Kotlin) under `qualityStatic`.

Style references:
- `docs/Octopus JVM Style Guidelines.md`
- `docs/Octopus Kotlin Style Guide.md`

### Merge contract (stack-agnostic)

Keep human-readable workflows in repositories:
- `Quality Gates`
- `Security Reports`

Add one orchestrator workflow (for example, `Merge Gate`) that aggregates merge decision:

```yaml
name: Merge Gate

on:
  pull_request:
  workflow_dispatch:

jobs:
  quality:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-quality-gates.yml@<octopus-base-tag>
    with:
      java-version: "21"

  security:
    permissions:
      security-events: write
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-security-reports.yml@<octopus-base-tag>
    with:
      java-version: "21"

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./gradlew build --no-daemon --stacktrace

  gate-merge:
    name: gate/merge
    if: ${{ always() }}
    needs: [quality, security, build]
    runs-on: ubuntu-latest
    steps:
      - name: Fail when any gate failed
        shell: bash
        run: |
          set -euo pipefail
          results='${{ toJson(needs) }}'
          failed="$(jq -r 'to_entries[] | select(.value.result != "success") | "\(.key): \(.value.result)"' <<<"${results}")"
          if [[ -n "${failed}" ]]; then
            echo "Merge gate failed:"
            echo "${failed}"
            exit 1
          fi
```

For repositories where some gate is not applicable, keep the job but make it explicit no-op with `success`.

### Suggested required checks in branch protection

Use exact check names as they appear in the consumer repository PR.

Real check names from `octopus-test`:
- `quality / quality / quality/static`
- `quality / quality / quality/tests-coverage`
- `security / security / security/codeql`
- `security / security / security/trivy`
- `build/gradle-public / build`
- `release-smoke / release/maven-public / prepare-build-publish-release`
- `gate/merge`

If the repository uses a unified merge contract, require only:
- `gate/merge`

Do not mark disabled or intentionally skipped jobs as required in branch protection. The release
workflows' `Tag and release` job is one of these: it runs only for a real release, so in a
consumer's dry-run smoke matrix it is always skipped and must never be a required check.

This keeps branch protection independent from implementation details (Gradle, Maven, Python, etc.).

### Merge Gates For Developers

From a developer point of view, the PR flow is intentionally simple:

- `Quality Gates` runs style, static analysis, tests, and coverage checks.
- `Security Reports` runs security scanners and publishes their results.
- `Merge Gate` is the final merge contract check.

In practice, developers only need to know one rule:
- if `gate/merge` is green, all required gates for that repository passed
- if `gate/merge` is red, open the failed upstream check and fix that specific problem

Where to look when a PR is red:

- Workflow summary for the failed check
- Job logs for the concrete failed step
- Workflow artifacts for raw reports
- `Security -> Code scanning alerts` for repositories that publish SARIF findings

Developers do not need to understand the reusable workflow internals or the `octopus-base` canary verification flow to work with the contract above.

Reference repository:
- `octopus-test` shows the intended developer-facing layout with `Quality Gates`, `Security Reports`, and `Merge Gate`
- Demo PR: `octopus-test#39` — https://github.com/octopusden/octopus-test/pull/39

### octopus-base specifics

In `octopus-base`, `Merge Gate` delegates `build` to reusable canary verification in `octopus-test`.
This makes downstream consumer verification a merge blocker while preserving the same external check contract:
- `gate/merge`
