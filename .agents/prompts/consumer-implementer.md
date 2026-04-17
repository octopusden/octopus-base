# Sub-Agent Playbook: Consumer Quality-Gates Implementer

## Purpose

Apply the octopusden quality-gates convention to a consumer JVM repository so that
every pull request is blocked by a mandatory `gate/merge` status check.

## Parameters (filled in by the orchestrator before dispatching this agent)

| Placeholder          | Example value              | Meaning                                                            |
|----------------------|----------------------------|--------------------------------------------------------------------|
| `{{REPO_NAME}}`      | `octopus-release-plugin`   | GitHub repository name (under the `octopusden` org)               |
| `{{JAVA_VERSION}}`   | `17`                       | JDK version used by the repo's CI runtime                         |
| `{{FLOW_TYPE}}`      | `public` \| `hybrid`           | Build flow type passed to `common-java-gradle-build.yml`; `public` runs tests, `hybrid` can skip them |
| `{{FT_EXCLUSIONS}}`  | `"integrationTest", ":ft:test"` | Fully quoted Kotlin argument list of Gradle task names/paths to exclude from the gate (or empty). The orchestrator must supply the value already formatted with double-quoted strings and commas so that `excludeTasks({{FT_EXCLUSIONS}})` is valid Kotlin DSL — e.g. `"integrationTest", ":ft:test"`. |
| `{{COVERAGE_ENABLED}}` | `true` \| `false`        | Whether to configure Kover coverage gates                         |
| `{{LANGUAGES}}`      | `kotlin,java`              | Comma-separated set of languages detected in `src/`               |
| `{{OCTOPUS_BASE_VERSION}}` | `v2.2.0`             | Tag of octopus-base release for all `uses:` refs                  |

---

## Step 1 — Apply the convention plugin

Open `build.gradle.kts` (root project) and add the quality plugin to the `plugins {}` block:

```kotlin
plugins {
    // …existing plugins…
    id("org.octopusden.octopus-quality")
}
```

If `{{COVERAGE_ENABLED}}` is `true`, also add a coverage override block after the `plugins {}` block
(adjust the threshold values to *current measured coverage + 5 percentage points*):

```kotlin
octopusQuality {
    coverage {
        minimumLineCoverage.set(java.math.BigDecimal("0.10"))   // per-module minimum
        overallMinimum.set(java.math.BigDecimal("0.72"))        // e.g. 0.72 if current coverage is 67 %
    }
}
```

If `{{COVERAGE_ENABLED}}` is `false`:

```kotlin
octopusQuality {
    coverage {
        enabled.set(false)
    }
}
```

If `{{FT_EXCLUSIONS}}` is non-empty, add task exclusions:

```kotlin
octopusQuality {
    excludeTasks({{FT_EXCLUSIONS}})   // e.g. excludeTasks("integrationTest", ":ft:test")
}
```

---

## Step 2 — Plugin version declarations

Open `settings.gradle.kts` (or `settings.gradle`) and ensure the
`pluginManagement { plugins { … } }` block declares a version for
`org.octopusden.octopus-quality` (mandatory for **all** consumers) plus
Kotlin-specific tools when `{{LANGUAGES}}` contains `kotlin`:

```kotlin
pluginManagement {
    plugins {
        // …existing entries…
        id("org.octopusden.octopus-quality")   version "<octopus-quality-version>"
        // Kotlin repos only — omit these for pure Java/Groovy:
        id("io.gitlab.arturbosch.detekt")      version "<detekt-version>"
        id("org.jlleitschuh.gradle.ktlint")    version "<ktlint-plugin-version>"
        id("org.jetbrains.kotlinx.kover")      version "<kover-version>"
    }
}
```

Use the latest released tag of `octopus-base` for `<octopus-quality-version>`.
For Kotlin tool versions, use what is already pinned in
`octopus-base/gradle-quality-plugin/gradle.properties` (or `libs.versions.toml`
if the consumer has one). Do **not** introduce a second copy of a version that
is already declared.

---

## Step 3 — Generate baselines (Kotlin repos only)

When `{{LANGUAGES}}` contains `kotlin`, run:

```bash
./gradlew detektBaseline
./gradlew ktlintGenerateBaseline
```

Commit the generated baseline files together with the rest of the changes:

- `detekt-baseline.xml` (root and any sub-project locations)
- The ktlint baseline file produced by `ktlintGenerateBaseline` (default: `build/ktlint/baseline.xml`; configure a repo-local committable path via `ktlint { baseline.set(...) }`)

---

## Step 4 — Add workflow files

Create or replace the three files below.  
**Keep the `# PUBLIC —` or `# INTERNAL —` comment on the first line of each file; it is a documentation convention used across octopusden workflows.**

### 4a. `.github/workflows/merge-gate.yml`

```yaml
# PUBLIC — every PR triggers this workflow and the gate/merge check must be green to merge.
name: Merge Gate

on:
  pull_request:
    branches: [ main ]

jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-build.yml@{{OCTOPUS_BASE_VERSION}}
    with:
      java-version: '{{JAVA_VERSION}}'
      flow-type: '{{FLOW_TYPE}}'
    secrets: inherit

  quality:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-quality-gates.yml@{{OCTOPUS_BASE_VERSION}}
    with:
      java-version: '{{JAVA_VERSION}}'
    secrets: inherit

  security:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-security-reports.yml@{{OCTOPUS_BASE_VERSION}}
    with:
      java-version: '{{JAVA_VERSION}}'
    secrets: inherit

  gate-merge:
    name: gate/merge
    needs: [ build, quality, security ]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: octopusden/octopus-base/.github/actions/merge-gate@{{OCTOPUS_BASE_VERSION}}
        with:
          needs: ${{ toJson(needs) }}
```

Replace `{{OCTOPUS_BASE_VERSION}}` with the current semver release tag of `octopus-base` (e.g. `v2.0.3`).
Do **not** use `@main`.

### 4b. `.github/workflows/quality.yml`

```yaml
# INTERNAL — triggered on push to main and manually; never on pull_request.
name: Quality

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  quality:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-quality-gates.yml@{{OCTOPUS_BASE_VERSION}}
    with:
      java-version: '{{JAVA_VERSION}}'
    secrets: inherit
```

### 4c. `.github/workflows/security.yml`

```yaml
# INTERNAL — triggered on push to main, nightly, and manually; never on pull_request.
name: Security

on:
  push:
    branches: [ main ]
  schedule:
    - cron: '0 3 * * 1'   # every Monday at 03:00 UTC
  workflow_dispatch:

jobs:
  security:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-security-reports.yml@{{OCTOPUS_BASE_VERSION}}
    with:
      java-version: '{{JAVA_VERSION}}'
    secrets: inherit
```

---

## Step 5 — Strip `pull_request:` from existing workflows

If `quality.yml` or `security.yml` already exist and have a `pull_request:` trigger, remove it.

```yaml
# BEFORE
on:
  push:
    branches: [ main ]
  pull_request:           # <-- remove this block entirely

# AFTER
on:
  push:
    branches: [ main ]
```

---

## Step 6 — Commit and open a PR

Stage all changed and new files, then commit with exactly this message:

```
chore: enable quality gates
```

Open a pull-request with:

- **Title:** `chore: enable quality gates for {{REPO_NAME}}`
- **Base branch:** `main`
- **Body:** brief description of what changed (plugin applied, workflows added, baselines committed)

Do **not** merge; wait for the `pr-reviewer` agent to approve.
