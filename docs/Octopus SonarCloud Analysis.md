# Octopus SonarCloud Analysis

How an `octopusden` repository gets analysed by SonarQube Cloud, what the analysis judges, and how
to adopt it.

Two reusable workflows live here:

| Workflow | For |
|---|---|
| `.github/workflows/common-java-gradle-sonar.yml` | Gradle repositories |
| `.github/workflows/common-java-maven-sonar.yml` | Maven repositories |

Pin them to a released tag, never `@main`.

This is separate from the self-hosted SonarQube Community Server driven from TeamCity. That path is
unaffected by anything here.

---

## Adopting it

### Prerequisites, on the SonarCloud side

A repository cannot be analysed until a SonarCloud project exists for it **and Automatic Analysis
is switched off on that project**. Both are handled by the repository-provisioning automation; the
second one matters because while Automatic Analysis is on, a CI analysis of the same project
*fails, and fails the build with it*.

`SONAR_TOKEN` must also be available to the repository. It is a SonarCloud token, not a GitHub one,
and it needs only *Execute Analysis*.

### Maven — nothing to change in the project

The scanner is a pinned command-line plugin invocation, so nothing about Sonar reaches the POM. Add
the caller and you are done:

```yaml
name: Sonar

on:
  push:
  pull_request:
    types: [ opened, synchronize, reopened ]
  workflow_dispatch:

jobs:
  sonar:
    uses: octopusden/octopus-base/.github/workflows/common-java-maven-sonar.yml@<octopus-base-tag>
    with:
      java-version: "8"
    secrets: inherit
```

### Gradle — apply the plugin, then add the caller

The consumer applies `org.sonarqube` itself, exactly as it already applies detekt and ktlint. Pin
the version in `gradle.properties`:

```properties
sonarqube.version=7.5.0.8588
```

Declare it in `settings.gradle.kts`:

```kotlin
pluginManagement {
    plugins {
        id("org.sonarqube") version settings.providers.gradleProperty("sonarqube.version")
    }
}
```

And apply it at the root of `build.gradle.kts`:

```kotlin
plugins {
    id("org.sonarqube")
}
```

**Do not add a `sonar { properties { … } }` block.** Every Sonar property is supplied by the
workflow, which is what keeps a change of SonarCloud organisation a configuration change rather
than a commit in every repository.

Then the caller:

```yaml
name: Sonar

on:
  push:
  pull_request:
    types: [ opened, synchronize, reopened ]
  workflow_dispatch:

jobs:
  sonar:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-sonar.yml@<octopus-base-tag>
    with:
      java-version: "21"
    secrets: inherit
```

`secrets: inherit` is required. Reusable workflows do not inherit secrets on their own, and a
caller without it fails on a missing secret rather than on anything Sonar-shaped.

---

## What gets analysed, and what counts as new

Sonar reports on **new code** — what a change adds — not on everything a repository contains. A
repository with hundreds of existing issues can adopt analysis without being asked to fix any of
them.

| What | Analysed when | New code is |
|---|---|---|
| `main` | every push | everything since the last release tag |
| feature branch | every push | its diff against `main` |
| pull request | opened, updated, reopened | the pull request's own diff |

Feature branches are compared against the default branch by a parameter the workflow sets per
analysis. Pull requests need no configuration — Sonar always treats the whole PR diff as new code,
and setting a reference branch on one can cause it to be analysed as a branch instead.

Until `main` itself has been analysed there is no baseline, so an early branch analysis shows only
that branch's changed files. It corrects itself as soon as anything lands on `main`.

### The version is the latest release tag, unmodified

`sonar.projectVersion` is the newest tag matching the release pattern, found the same way the
release pipeline finds it. It is deliberately passed through untouched.

Sonar's "previous version" means *new code starts where the version last changed*, so anything
appended to the tag breaks it, silently and in one of two directions:

- **A version that never changes** — a `1.0-SNAPSHOT` placeholder, say — never advances the
  baseline, so new code on `main` means every commit since the first analysis, forever.
- **A version that changes every build** — a timestamp, a commit count — moves the baseline every
  run, so an issue is new code for exactly one analysis and old code on the next commit. Reported
  once, then never again.

A plain tag changes exactly when a release happens, so new code accumulates across a release cycle
and resets when you ship. Sonar already records the commit SHA and date on every analysis, so the
version field does not need to carry them.

---

## Passing and failing

The job does not finish when the report is uploaded. It waits for SonarCloud to evaluate the
quality gate, and **a red gate fails the job**. Where the Sonar check is required by branch
protection, that blocks the merge.

`quality-gate-wait` controls this and defaults to `true`. Pass `false` to report without blocking —
useful when first adopting analysis in a repository, so the results can be looked at before they
start gating merges.

The pull request comment and inline annotations come from the SonarCloud GitHub App, posted
server-side. They are how a developer sees the result; they are not what enforces it. The workflow
needs no `pull-requests: write`.

### Coverage is not reported

The analysis does not send a coverage report, so Sonar shows **0% coverage** on every project. That
is expected, not a misconfiguration.

It has one consequence worth knowing: SonarCloud's stock quality gate contains a
coverage-on-new-code condition, which 0% can never satisfy. A repository judged by the stock gate
therefore fails every pull request that touches code, whatever its quality. Blocking requires a
gate without that condition.

Because coverage is not reported, the analysis also **compiles tests without running them**. Sonar
needs bytecode, not test results. This keeps a flaky test from reddening a code analysis, and it
has to be reversed when coverage is introduced — at which point the analysis must run in the same
job that produces the coverage report, since no workflow can read another's files.

---

## Java versions

The limit is the JVM the **scanner** runs in, not the bytecode the project targets.

| Scanner runtime | Supported |
|---|---|
| Java 21+ | directly |
| Java 11 / 17 | with JRE auto-provisioning — the scanner fetches its own JDK 21 |
| Java 8 | not at all; the plugin cannot load |

**Gradle** repositories need no special handling at any version. Gradle runs on the project's own
JDK and the scanner provisions what it needs underneath, so `java-version` is simply the version
the project builds with.

**Maven** repositories on Java 8 cannot load the scanner in the build JVM, so the workflow installs
two JDKs: the project builds on its own, and the analysis runs as a separate invocation on JDK 21
with `sonar.java.jdkHome` pointed back at the build JDK. This is automatic — `java-version` is
still just the project's version — and it works for Atlassian AMPS projects too.

---

## Workflow inputs

Shared by both workflows:

| Input | Default | Purpose |
|---|---|---|
| `java-version` | *required* | The JDK the project builds with |
| `java-distribution` | `temurin` | Passed to `actions/setup-java` |
| `runs-on` | `ubuntu-latest` | Runner label |
| `timeout-minutes` | `20` | Job timeout |
| `sonar-host-url` | `https://sonarcloud.io` | Sonar server |
| `sonar-organization` | the GitHub owner | Sonar organisation key |
| `sonar-project-key` | `<owner>_<repo>` | Sonar project key |
| `default-branch` | the repository's own | What feature branches are compared against |
| `quality-gate-wait` | `true` | Fail the job on a red gate |
| `version-tag-regex` | `^v([0-9]+)\..*` | Which tags count as releases |
| `fallback-version` | `0.0.0` | Version for a repository with no release tag |
| `continue-on-error` | `false` | Report without failing the workflow |

Gradle only:

| Input | Default | Purpose |
|---|---|---|
| `sonar-command` | `./gradlew build -x test sonar --no-daemon --stacktrace` | The analysis command |

Maven only:

| Input | Default | Purpose |
|---|---|---|
| `scanner-java-version` | `21` | The JDK the scanner runs on |
| `scanner-maven-plugin-version` | `5.7.0.6970` | Pinned scanner plugin |
| `mvn-parameters` | *(empty)* | Extra parameters for the build invocation |

Secret: `SONAR_TOKEN`, required.

---

## Troubleshooting

**"You are running CI analysis while Automatic Analysis is enabled."**
Automatic Analysis is on for that project. It is enabled by default whenever a project is imported,
and re-enabled if a project is deleted and re-imported. Switch it off under *Project →
Administration → Analysis Method*. This is the most common cause of a Sonar job failing for no
apparent reason.

**The job fails on a missing secret.**
The caller is missing `secrets: inherit`.

**The gate fails on coverage.**
The project is on a quality gate that includes a coverage condition. Coverage is not reported — see
above.

**Sonar reports no issues on a pull request.**
Expected when the pull request changes no analysable source. Sonar reports on what the change
touches, not on what the repository contains.

**A branch analysis shows only a handful of files and no overall code.**
`main` has not been analysed yet, so there is no baseline. It resolves once anything lands on
`main`.

**The project reads as suspiciously clean.**
Check that the analysis compiled the project. Without bytecode the analysis still succeeds, minus
every rule that needs type resolution. The workflows build before analysing for exactly this
reason; a customised `sonar-command` that skips the build reintroduces it.
