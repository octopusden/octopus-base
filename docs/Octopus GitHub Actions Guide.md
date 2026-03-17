:exclamation: **NOTE:** _This article needs to be revised_

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
      pattern: ^v([0-9]+)\.?([0-9]+)?\.?([0-9]+)?
```

## Jobs

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    environment: Prod
```
Where 'environment: Prod' it is an environment is used to describe a general deployment target.

## Steps

In general block 'Steps' should contain the following operations:

- Checkout and switch to a commit
- Set up JDK
- Build project
- Publish artifacts to sonatype
- Create a docker image and publish it to **ghcr.io**

## Calculate a version on the GH side

To get the version from the tag(when the version is no input parameter):
```yaml
  - uses: actions-ecosystem/action-get-latest-tag@v1
    id: tag_version
    with:
      initial_version: v2.0.0
```
[More information about this action](https://github.com/marketplace/actions/actions-ecosystem-action-get-latest-tag)

To upgrade the version:
```yaml
  - uses: actions-ecosystem/action-bump-semver@v1
    id: bump_semver
    with:
      current_version: ${{ steps.tag_version.outputs.tag }}
      level: patch
```
[More information about this action](https://github.com/actions-ecosystem/action-bump-semver)

## Publication

Publication looks like a gradle task execution. Example:

```yaml
- name: Publish
  run: ./gradlew publishToSonatype closeAndReleaseSonatypeStagingRepository -Pversion=${{ github.event.client_payload.project_version }}
  env:
    MAVEN_USERNAME: ${{ secrets.OSSRH_USERNAME }}
    MAVEN_PASSWORD: ${{ secrets.OSSRH_TOKEN }}
    ORG_GRADLE_PROJECT_signingKey: ${{ secrets.GPG_PRIVATE_KEY }}
    ORG_GRADLE_PROJECT_signingPassword: ${{ secrets.GPG_PASSPHRASE }}
    BUILD_VERSION: ${{ github.event.client_payload.project_version }}
```

To publish to the docker registry:
- login to **ghcr.io**
```yaml
    - name: Log in to Docker Hub
      uses: docker/login-action@v2
      with:
        registry: ghcr.io
        username: ${{ github.repository_owner }}
        password: ${{ secrets.GITHUB_TOKEN }}
```
- and push an image
```yaml
    - name: Push to docker registry
      run: docker push ghcr.io/$GITHUB_REPOSITORY:${{ github.event.client_payload.project_version }}
```

## Examples

- [Release workflow(non-docker)](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/release.yml)
- [Release workflow(with docker)](https://github.com/octopusden/octopus-employee-service/blob/main/.github/workflows/buildAndRelease.yml)
- [Build workflow](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/build.yml)

## Reusable Quality and Security Gates (Gradle)

Use reusable workflows from `octopus-base` to avoid copy-paste between repositories.

Pin reusable workflow references to a released tag (for example `@v1.2.0`), not `@main`.
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

For mixed JVM repositories (`Java` + `Kotlin` + `Groovy`), keep these tasks language-agnostic and aggregate all enabled tools (for example `checkstyle`/`pmd`/`spotbugs`/`codenarc`/`detekt`/`ktlint`) under `qualityStatic`.

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

Do not mark disabled or intentionally skipped jobs as required in branch protection.

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
