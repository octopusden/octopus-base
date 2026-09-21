# Octopus SonarCloud Analysis

How an `octopusden` repository gets analysed by SonarQube Cloud, what the analysis judges, and how
to adopt it.

Two reusable workflows live here:

| Workflow | For |
|---|---|
| `.github/workflows/common-java-gradle-sonar.yml` | Gradle repositories |
| `.github/workflows/common-java-maven-sonar.yml` | Maven repositories |

Pin them to a released tag, never `@main`.

---

## Adopting it

### Prerequisites, on the SonarCloud side

A repository cannot be analysed until a SonarCloud project exists for it **and Automatic Analysis
is switched off on that project**. Both are handled by the repository-provisioning automation; the
second one matters because while Automatic Analysis is on, a CI analysis of the same project
*fails, and fails the build with it*.

`SONAR_TOKEN` must also be available to the repository. It is a SonarCloud token, not a GitHub one,
and it needs only *Execute Analysis*. It lives in the **`Prod` environment**, which both workflows
declare, alongside the other release credentials.

That is why both workflows declare the secret `required: false` while the analysis cannot run
without it. `secrets: inherit` passes repository-level secrets only; an environment secret is
resolved by the job, after it starts. Declaring it required makes the workflow fail at startup
with no steps and no log — a failure that names nothing and points nowhere.

The project's new-code definition must be **Previous version**, which is the SonarCloud default and
what provisioning sets. The version scheme below depends on it, so a project someone has
reconfigured needs it put back.

### Maven — add the caller, and check the Kotlin source roots

The scanner is a pinned command-line plugin invocation, so nothing about Sonar reaches the POM. A
repository with Kotlin sources has one thing to check first — see below. Otherwise add the caller
and you are done:

```yaml
name: Sonar

on:
  push:
    branches: [ '**' ]
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

#### Kotlin sources have to be registered in the POM

`kotlin-maven-plugin` compiles `src/main/kotlin` and `src/test/kotlin` through its own `sourceDirs`,
which never enter the Maven model. The scanner reads the model, so a repository that registers
nothing is analysed as its `src/main/java` alone — successfully, in green, reporting on a fraction
of the code. Four repositories passed this way before it was noticed.

`octopus-parent` 2.1.0 and later registers both roots, so a repository on that parent needs
nothing. On an older parent, register them with `build-helper-maven-plugin`:

```xml
<plugin>
    <groupId>org.codehaus.mojo</groupId>
    <artifactId>build-helper-maven-plugin</artifactId>
    <version>3.6.1</version>
    <executions>
        <execution>
            <id>add-main-kotlin-sources</id>
            <phase>generate-sources</phase>
            <goals><goal>add-source</goal></goals>
            <configuration><sources><source>src/main/kotlin</source></sources></configuration>
        </execution>
        <execution>
            <id>add-test-kotlin-sources</id>
            <phase>generate-sources</phase>
            <goals><goal>add-test-source</goal></goals>
            <configuration><sources><source>src/test/kotlin</source></sources></configuration>
        </execution>
    </executions>
</plugin>
```

Both executions must be bound to `generate-sources`, including the test one. The analysis is a
second `mvn` process that runs `generate-sources` and then the scanner goal, so a registration
bound to any later phase — `generate-test-sources` is the obvious choice, and the wrong one — never
executes. It cannot simply run later either: `octopus-parent` binds `maven-javadoc-plugin:jar` to
`generate-resources`, so a scanner invocation reaching that phase rebuilds javadoc on the scanner
JDK and fails.

Verify by counting, not by reading the log for the word Kotlin. The analysis log reports
`N source files to be analyzed` under the Kotlin sensor; that number should match the `.kt` files on
disk. The weaker check — grepping for `Quality profile for kotlin` — passes as soon as a single
Kotlin file is indexed anywhere, including one that happens to sit under `src/main/java`.

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

A repository may add its own `sonar { properties { … } }` block for anything specific to it —
`sonar.exclusions`, `sonar.coverage.exclusions`, extra source or test directories.

What it should **not** set is the properties the workflow already supplies: `sonar.projectKey`,
`sonar.organization`, `sonar.projectVersion`, `sonar.host.url`, `sonar.qualitygate.wait` and
`sonar.newCode.referenceBranch`. The workflow passes those on the command line, where they take
precedence over anything in the build script — so setting them there does nothing, while looking
as though it does. Leaving them to the workflow is also what keeps a change of SonarCloud
organisation a configuration change rather than a commit in every repository.

Then the caller:

```yaml
name: Sonar

on:
  push:
    branches: [ '**' ]
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

`branches: [ '**' ]` is what keeps tags out. A bare `push:` also fires on tag pushes, and Sonar
would then record the release tag as a branch of its own. The workflow no longer gives such a run
a reference branch, but it still analyses it.

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

### The version is the latest release tag

`sonar.projectVersion` is the newest tag matching the release pattern, found the same way the
release pipeline finds it, with the leading `v` dropped — so `v2.0.8` is reported as `2.0.8`,
matching the coordinates the released artifacts actually carry.

Nothing else is derived from it. Sonar's "previous version" means *new code starts where the
version last changed*, so the only property that matters is that it changes at a release and
nowhere else. Anything appended to the tag breaks that, silently and in one of two directions:

- **A version that never changes** — a `1.0-SNAPSHOT` placeholder, say — never advances the
  baseline, so new code on `main` means every commit since the first analysis, forever.
- **A version that changes every build** — a timestamp, a commit count — moves the baseline every
  run, so an issue is new code for exactly one analysis and old code on the next commit. Reported
  once, then never again.

A release tag changes exactly when a release happens, so new code accumulates across a release
cycle and resets when you ship. Sonar already records the commit SHA and date on every analysis, so the
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

Because coverage is not reported, the analysis **compiles tests without running them**. Sonar needs
bytecode, not test results — and analysing test sources without their bytecode would silently skip
every rule that needs type resolution, so the compilation is not optional. This keeps a flaky test from reddening a code analysis, and it
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

The Maven workflow works around this by running the analysis in a second JVM. Gradle cannot: see
below.

**Gradle** repositories need **Java 11 or later**. The `org.sonarqube` plugin is compiled for Java
11 and is loaded by the build JVM itself, before scanner JRE auto-provisioning can do anything
about it, so a Java 8 Gradle build fails while resolving the plugin. Above that floor there is
nothing to handle: Gradle runs on the project's own JDK and the scanner provisions JDK 21
underneath, so `java-version` is simply the version the project builds with. Every Gradle
repository in `octopusden` is already on 11 or later.

A Gradle repository pinned to Java 8 has no supported configuration here — the Maven workflow's
two-JDK split has no Gradle equivalent, because the plugin has to load in the build's own JVM.

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
| `sonar-command` | `./gradlew build testClasses -x test sonar --no-daemon --stacktrace` | The analysis command |

Maven only:

| Input | Default | Purpose |
|---|---|---|
| `scanner-java-version` | `21` | The JDK the scanner runs on |
| `scanner-maven-plugin-version` | `5.7.0.6970` | Pinned scanner plugin |
| `mvn-parameters` | *(empty)* | Extra Maven parameters, passed to **both** the build and the analysis |

Secret: `SONAR_TOKEN`. Declared optional in both workflow contracts, but the analysis cannot run
without it — see *Prerequisites* for why the declaration reads that way.

---

## Known limits

Both of these are accepted behaviour, not bugs waiting to be fixed. They are written down because
each one surfaces as a red check that looks like something else.

### `-x test` does not exclude every test

The Gradle command excludes the task named `test`. A repository that wires `integrationTest`,
`functionalTest` or anything similar into `check` still runs it under `build`, so a slow or
infrastructure-dependent suite runs during analysis and can fail it.

Such a repository should pass its own `sonar-command`, naming the compile tasks it wants instead of
`build` — for example `./gradlew classes testClasses sonar --no-daemon`. Whatever it names must
still compile both source sets: analysis without bytecode silently drops every rule needing type
resolution.

### Pull requests from forks cannot be analysed

GitHub withholds repository and environment secrets from a pull request opened from a fork, so
`SONAR_TOKEN` is empty there whatever the caller does. The job runs and fails on authentication.

There is no fix that keeps the analysis: `pull_request_target` would supply the token, and would
run a fork's build code with it. For an external contribution, read the analysis from the branch
after the change merges.

---

## Troubleshooting

- **"You are running CI analysis while Automatic Analysis is enabled."** Automatic Analysis is on
  for that project. It is enabled by default whenever a project is imported, and re-enabled if a
  project is deleted and re-imported. Switch it off under *Project → Administration → Analysis
  Method*. This is the most common cause of a Sonar job failing for no apparent reason.

- **The job fails on a missing secret.** The caller is missing `secrets: inherit`. Every level of a
  nested call chain needs it, not just the innermost one.

- **The job fails at startup, with no steps and no log.** `SONAR_TOKEN` is not reaching the job.
  Check that the repository has it in the `Prod` environment.

- **The gate fails on coverage.** The project is on a quality gate that includes a coverage
  condition. Coverage is not reported — see above.

- **Sonar reports no issues on a pull request.** Expected when the pull request changes no
  analysable source. Sonar reports on what the change touches, not on what the repository contains.

- **A branch analysis shows only a handful of files and no overall code.** `main` has not been
  analysed yet, so there is no baseline. It resolves once anything lands on `main`.

- **A property set in the build script has no effect.** It is probably one the workflow supplies on
  the command line, which wins. See the Gradle section above for which ones those are.

- **The project reads as suspiciously clean.** Check that the analysis compiled the project.
  Without bytecode the analysis still succeeds, minus every rule that needs type resolution. The
  workflows build before analysing for exactly this reason; a customised `sonar-command` that skips
  the build reintroduces it.
