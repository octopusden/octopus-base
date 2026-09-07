# Octopus JVM Style Guidelines

This document defines common static-analysis and style conventions for JVM services (`Java`, `Kotlin`, `Groovy`).

## Scope

- Kotlin linters: `detekt`, `ktlint`
- Java linters: `checkstyle`, `pmd`, `spotbugs` (as applicable)
- Groovy linter: `codenarc` (as applicable)
- Coverage reports: `jacoco` and/or `kover`
- Baseline/suppression files: repository-specific
- Technical debt references: `docs/Octopus Tech Debt Register.md`

## CI Quality Gate

Recommended CI tasks:

```bash
./gradlew qualityStatic
./gradlew qualityCoverage
```

Where:
- `qualityStatic` runs repository static checks (toolset depends on language mix).
- `qualityCoverage` runs tests and coverage validation.

## Recommended Tool Matrix

- Kotlin-heavy repositories: `detekt`, `ktlint`, `kover` or `jacoco`
- Java-heavy repositories: `checkstyle`, `pmd`, `spotbugs`, `errorprone` (opt-in), `jacoco`
- Groovy repositories: `codenarc`, `jacoco`
- Mixed repositories: use only tools that are already integrated, but keep one common entrypoint: `qualityStatic` and `qualityCoverage`

## Kotlin Style Guide

Detailed Kotlin-specific rule examples are documented separately:

- `docs/Octopus Kotlin Style Guide.md`

Use this JVM guide as the shared contract for language mix, CI entrypoints, and baseline strategy.

## Java And Groovy Rules

### `checkstyle`

- Keep code formatting and naming consistent.
- Prefer fail-fast on newly introduced violations.

### `pmd` / `spotbugs`

- Enable bug-prone and correctness categories first.
- Tune noise with explicit suppressions instead of disabling full rule groups.

### `errorprone`

Opt-in per repository:

```groovy
octopusQuality {
    java {
        failOnViolation = true
        errorProne = true
    }
}
```

- Applies to every module with `.java` source. Unlike SpotBugs it reads Java *source* inside
  javac, so a Kotlin module is simply invisible to it and needs no exclusion.
- Only ErrorProne's **on-by-default ERROR checks** run — the plugin sets `disableAllWarnings`.
  That set is the part ErrorProne treats as always-a-bug, so it needs no baseline and no tuning.
  The warning set on legacy code is a wall of findings nobody triages, which is why it is off.
- **Per-check tuning is not available from your build script.** The plugin applies
  `net.ltgt.errorprone` from its own `afterEvaluate`, so `options.errorprone` does not yet exist
  while your subproject script evaluates: a top-level
  `tasks.withType<JavaCompile> { options.errorprone.disable("X") }` throws
  `UnknownDomainObjectException`. Silence a finding with `@SuppressWarnings("CheckName")` at the
  narrowest scope instead. If a repository genuinely needs to configure the extension, it must
  queue its own `afterEvaluate` (which runs after the plugin's):

  ```groovy
  afterEvaluate {
      tasks.withType(JavaCompile).configureEach {
          options.errorprone.disable("SomeCheck")
      }
  }
  ```
- Whether a finding fails the build follows the same `java.failOnViolation` switch as
  checkstyle/pmd/spotbugs. With it off, findings are printed as warnings — **except** for the
  small set of ERROR checks ErrorProne marks non-disableable (e.g.
  `UnicodeDirectionalityCharacters`), which fail the compile regardless. ErrorProne demotes only
  checks declaring `disableable = true`; suppress a non-disableable one at the call site.
- **There is no report file.** Findings are javac diagnostics on the `compileJava` output, and that
  has a consequence the other analysers do not share: when `compileJava` is `UP-TO-DATE` or
  `FROM-CACHE`, the findings are simply absent. Checkstyle/PMD/SpotBugs leave an XML report on disk
  as a task output, which a skipped or cached run still restores; ErrorProne leaves nothing. So in
  warn-only mode (`failOnViolation = false`) a clean-looking build is not evidence of clean code —
  it may just be a compile that never re-ran. **Prefer `failOnViolation = true`**, where a violation
  fails the compile and the failure is never cached as a success; treat warn-only as a short
  migration step, not a steady state, and re-read it from a clean build.
- The engine supports a bounded JDK range and crashes outside it, in a way `failOnViolation` cannot
  downgrade. The default pin serves JDK 11-23; a repo on a newer JDK sets
  `java { errorProneVersion = "..." }` (2.50.0 covers 21 and 25). Too *low* a compile JDK for the
  chosen engine is caught for you, with a message naming both; too high is not — check the
  engine/JDK table in `docs/Octopus Quality Plugin CI Reference.md` before bumping.
- **Pre-check before opting in a module that already uses annotation processors.** The ErrorProne
  Gradle plugin makes `annotationProcessor` extend the `errorprone` configuration, so the engine's
  own tree (Guava, protobuf-java, dataflow-errorprone, pcollections, auto-common) joins your
  processor path and Gradle conflict resolution may bump a shared dependency there. Lombok in
  particular has known upstream friction with ErrorProne.
- A module counts as "having Java" when `src/main/java` or `src/test/java` **exists** — the check is
  the directory, not its contents, shared with checkstyle/pmd. An empty or leftover `src/main/java`
  therefore opts a module in, which for ErrorProne means resolving the engine and forking javac to
  analyse nothing. Delete stale source directories.

### `codenarc` (Groovy)

- Keep rules aligned with project style and gradually reduce legacy suppressions.
- Track intentional suppressions with `TD-xxx` references.

## Default Thresholds To Review

If enabled for a repository, start with defaults and tune only when there is a clear reason:

- `detekt:complexity:LongMethod`
- `detekt:complexity:LongParameterList`
- `detekt:complexity:NestedBlockDepth`
- `detekt:style:MagicNumber`
- `detekt:style:ReturnCount`

## Convention Plugin Setup

The `org.octopusden.octopus-quality` convention plugin (in `gradle-quality-plugin/`) provides shared configuration (rules, baselines, reports, task wiring) for quality tools. Consumer repos declare and apply the quality tool plugins themselves (with their own versions), and the convention plugin configures them. This gives repos `qualityStatic`, `qualityCoverage`, and `qualityCheck` aggregate tasks.

> For the pinned tool-version matrix (detekt, ktlint, kover, checkstyle, pmd, spotbugs, codenarc), the Kotlin/JDK generation each targets (including the detekt run-on-JDK-17-or-21, not-25 caveat), and the exact per-analyzer report output paths for consuming from any CI system, see `docs/Octopus Quality Plugin CI Reference.md`.

### Prerequisites

- **CI runtime JDK >= 11** (plugin bytecode target is JDK 11; Checkstyle 10.x also requires 11+)
- **Gradle 8.x+**

### Consumer wiring

```kotlin
// settings.gradle.kts — declare ALL plugin versions here:
pluginManagement {
    plugins {
        kotlin("jvm") version(extra["kotlin.version"] as String)
        id("io.gitlab.arturbosch.detekt") version(extra["detekt.version"] as String)
        id("org.jlleitschuh.gradle.ktlint") version(extra["ktlint-gradle.version"] as String)
        id("org.jetbrains.kotlinx.kover") version(extra["kover.version"] as String)  // Kotlin-only repos
        id("org.octopusden.octopus-quality") version "<octopus-base-version>"
    }
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

// build.gradle.kts — apply at root:
plugins {
    kotlin("jvm") apply false                          // only if repo has Kotlin
    id("io.gitlab.arturbosch.detekt") apply false      // only if repo has Kotlin
    id("org.jlleitschuh.gradle.ktlint") apply false    // only if repo has Kotlin
    id("org.jetbrains.kotlinx.kover") apply false      // only if Kotlin-only (no Java/Groovy)
    id("org.octopusden.octopus-quality")
}

// --- Kotlin-only repo (all subprojects are Kotlin): ---
subprojects {
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "io.gitlab.arturbosch.detekt")
    apply(plugin = "org.jlleitschuh.gradle.ktlint")
    apply(plugin = "org.jetbrains.kotlinx.kover")
}

// --- Mixed repo (some Kotlin, some Java/Groovy): ---
// Apply Kotlin tools selectively per module:
//   project(":api") {
//       apply(plugin = "org.jetbrains.kotlin.jvm")
//       apply(plugin = "io.gitlab.arturbosch.detekt")
//       apply(plugin = "org.jlleitschuh.gradle.ktlint")
//   }
// Java/Groovy modules need NO extra apply — the convention plugin auto-applies
// checkstyle, pmd, codenarc based on source dirs (and spotbugs on modules with
// Java and no Kotlin — it false-positives on Kotlin bytecode).

// Optional overrides:
octopusQuality {
    coverage {
        enabled.set(false)                          // disable for repos without tests
        tool.set(CoverageExtension.Tool.AUTO)       // AUTO (default), JACOCO, or KOVER
        minimumLineCoverage.set(BigDecimal("0.10"))  // per-module default
        overallMinimum.set(BigDecimal("0.70"))       // overall default
    }
    kotlin { failOnViolation.set(false) }            // report-only (rollout default)
    java   { failOnViolation.set(false) }
    groovy { failOnViolation.set(false) }
    excludeTasks("integrationTest", ":ft:test")      // exclude env-dependent tests
    excludeProjects("test-common")                   // exclude from coverage
}
```

> **Version ownership:** Consumer repos own the versions of Kotlin, detekt, ktlint, and kover — declared in `pluginManagement` and pinned in `gradle.properties`. The convention plugin configures these tools (shared rules, baselines, reports, task wiring) but does NOT pin their versions. This decouples tool version upgrades from the convention plugin release cycle.

### What the plugin provides vs what the consumer provides

| Component | Provider | Why |
|-----------|----------|-----|
| Tool **configuration** (shared rules, baselines, reports, task wiring) | Convention plugin | Org-wide consistency |
| Tool **versions** (detekt, ktlint, kover, kotlin) | Consumer repo (`gradle.properties`) | Coupled to Kotlin version |
| Checkstyle, PMD, CodeNarc configs | Convention plugin (bundled) | Shared org-wide rules |
| SpotBugs plugin | Convention plugin (`implementation`) | No Kotlin version coupling |
| JaCoCo plugin | Convention plugin (Gradle built-in) | No version coupling |

### What the plugin auto-configures (when consumer applies the tool)

| Language detected | Tools configured | Coverage |
|-------------------|-----------------|----------|
| Kotlin (no Java) | detekt + ktlint | Kover (consumer applies kover plugin) |
| Java (no Kotlin) | checkstyle + pmd + spotbugs (+ errorprone when opted in) | JaCoCo (plugin applies jacoco) |
| Groovy (no Java) | codenarc | JaCoCo (plugin applies jacoco) |
| Mixed Java + Kotlin | detekt + ktlint + checkstyle + pmd (+ errorprone when opted in) | JaCoCo |

> **Checkstyle/PMD** are Java-only tools — they are applied only to modules that have Java source. A Kotlin-only module gets detekt + ktlint; a Groovy-only module gets codenarc; only Java (Java-only or mixed Java + Kotlin/Groovy) gets checkstyle + pmd.
>
> **SpotBugs** is wired only on modules that have Java **and no Kotlin** (Java-only or Java+Groovy). It analyses *bytecode* and false-positives heavily on compiled Kotlin (lateinit / DSL getters / synthetic accessors), so any module containing Kotlin is skipped.
>
> **ErrorProne** is **off unless the repo opts in** (`java { errorProne = true }`) and is applied only then — applying it "disabled" would still put the analyser on javac's plugin path and fork the compiler. Once on, it covers every Java-source module, mixed ones included: it reads Java source inside javac, so Kotlin is invisible to it rather than a source of false positives.

### What stays local in each repo

| File | Purpose |
|------|---------|
| `detekt-baseline.xml` | Legacy detekt violations (per module) |
| `ktlint-baseline.xml` | Legacy ktlint violations (per module) |
| `.editorconfig` | Editor / ktlint config |
| Coverage threshold overrides | Per-repo maturity |

### GitHub Actions workflows

Each repo adds two workflow files that call reusable workflows from octopus-base:

- `.github/workflows/quality.yml` → `common-java-gradle-quality-gates.yml`
- `.github/workflows/security.yml` → `common-java-gradle-security-reports.yml`

See `docs/Octopus GitHub Actions Guide.md` for workflow details and inputs.

## Maven Central Publication Validation

For repos that publish to Maven Central via `maven-publish`, the convention plugin automatically registers a `validatePublications` task when both `maven-publish` and `org.octopusden.octopus-quality` are applied. The task is wired into `check` — so it runs on every PR build and catches Central-incompatible publications before publish time.

### What is validated

**POM metadata** (parsed from generated POM XML, direct `<project>` children only):

| Field | Required |
|-------|:--------:|
| `<name>` | yes |
| `<description>` | yes |
| `<url>` | yes |
| `<licenses>` | yes (at least one `<license>`) |
| `<developers>` | yes (at least one `<developer>`) |
| `<scm>` | yes |

**Artifacts** (for non-pom publications):

| Artifact | Required |
|----------|:--------:|
| `-sources.jar` | yes |
| `-javadoc.jar` | yes |

**pom-only publications** (java-platform, BOM, version-catalog) are exempt from artifact checks — only POM metadata is validated.

### Consumer example

```kotlin
plugins {
    kotlin("jvm")
    `maven-publish`
    id("org.octopusden.octopus-quality")
}

java {
    withSourcesJar()
    withJavadocJar()
}

publishing {
    publications {
        create<MavenPublication>("mavenJava") {
            from(components["java"])
            pom {
                name.set(project.name)
                description.set("Octopus module: ${project.name}")
                url.set("https://github.com/octopusden/${rootProject.name}")
                licenses {
                    license {
                        name.set("The Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                scm {
                    url.set("https://github.com/octopusden/${rootProject.name}")
                    connection.set("scm:git://github.com/octopusden/${rootProject.name}.git")
                }
                developers {
                    developer {
                        id.set("octopus")
                        name.set("octopus")
                    }
                }
            }
        }
    }
}
```

With this setup, `./gradlew check` includes `validatePublications` automatically. If any required field is missing or sources/javadoc JARs are absent, the build fails with a clear error message listing exactly what is wrong.

## Public API Boundary And Version Increments

Semantic Versioning requires a declared API as a precondition, not as an optional extra: *"Software using Semantic Versioning MUST declare a public API. This API could be declared in the code itself or exist strictly in documentation."* ([semver.org](https://semver.org/), rule 1). All three increment rules are defined **relative to that API** — rule 6 (patch: backward compatible bug fixes), rule 7 (minor: new backward compatible functionality **to the public API**), rule 8 (major: backward incompatible changes **to the public API**).

Consequence: a component whose API boundary is not declared cannot have its version level checked at all. Declaring the boundary is therefore the first step, and it differs by component role.

### What counts as API, per component type

| Component type | Its public API is | Everything else | What must be compared against the previous release |
|----------------|-------------------|-----------------|-----------------------------------------------------|
| **Library** (consumed via `dependencies { }`) | Public types and members in non-internal packages | Implementation classes | The published bytecode API surface |
| **Gradle convention plugin** | Plugin ID, extension DSL (properties, nested blocks, `fun`s), **`convention(...)` default values**, registered task names, what is wired into `check` | All classes, including the extension's implementation | The DSL and its defaults — not the bytecode |
| **Service / application** (no downstream library consumers) | REST contract (`/rest/api/{api-version}` + generated OpenAPI), configuration keys and their defaults, DB schema and migrations, message/event payloads, Docker contract (ports, volumes, healthcheck) | **All code — may be fully internal** | The generated OpenAPI spec and the config key set |
| **BOM / version catalog / parent POM** | Declared coordinates and version constraints | — | The declared constraints |

A service having no downstream services does **not** mean it has no public API — it means the API is not in the bytecode. Marking all of its code internal is correct; judging its version by an API diff of that code is not.

The last column states *what* must be compared, not *how*. No comparison is automated in any Octopus release workflow today, so all of it is currently a review responsibility. Tool selection per component type is a separate decision.

### Increment level, per API plane

| Change | Level |
|--------|-------|
| New endpoint, new config key with a safe default, new DSL property, new public type | minor |
| Behavior fix with no contract change | patch |
| Removed or renamed endpoint, config key, DSL property, or public member | major |
| Changed default value that alters existing consumers' behavior | major |
| Internal refactor, no contract change | patch |

Changing a `convention(...)` default or a config default alters consumer behavior without changing any signature. This is invisible to every API-diff tool and must be classified manually.

### Marking internals

Octopus marks internals by **package name**, because it is the only mechanism that works identically in Java, Kotlin and Groovy. Where the language has a visibility modifier, it is required in addition.

| Mechanism | Java | Kotlin | Groovy |
|-----------|:----:|:------:|:------:|
| `*.internal.*` package name | required | required | required |
| `internal` modifier | not in the language | required | not in the language |

Rules:

- Anything under a `*.internal.*` package is **not** a contract and may change in a patch release.
- Anything outside it in a published artifact **is** a contract.
- In Kotlin, declarations in `*.internal.*` must also carry the `internal` modifier. Note that Kotlin `internal` compiles to `public` in bytecode — the compiler mangles internal *member* names, but **public members of an internal class are not mangled** and stay callable from Java ([Calling Kotlin from Java](https://kotlinlang.org/docs/java-to-kotlin-interop.html)). The modifier documents intent; it does not hide anything from bytecode tooling.
- Therefore any API-diff tool must be configured with the boundary explicitly, e.g. `japicmp -e 'org.octopusden.octopus.<module>.internal'`. Without it, japicmp's default access level treats every `public`/`protected` bytecode member as API and reports internal refactors as breaking changes.

Why by namespace: the JDK identifies its own internals the same way (`sun.*`, `jdk.internal.*`, [JEP 260](https://openjdk.org/jeps/260)), strongly encapsulated by default since [JEP 396](https://openjdk.org/jeps/396).

Not part of this standard: `@ApiStatus.Internal` (would add an `org.jetbrains:annotations` dependency) and JPMS `module-info.java` `exports` (not used in any Octopus component today). Both are valid ways to declare the boundary and are cited here only so the choice is not re-argued — adopting either is a separate decision.

## Baseline Strategy

- Baseline/suppressions are allowed only for existing violations.
- New code must pass without introducing extra baseline entries.
- Every baseline/suppression item must have a cleanup plan if it is non-trivial.

## Recommended Review Process

1. Enable rule in warning/report mode.
2. Capture current baseline.
3. Fix new violations first.
4. Gradually burn down baseline items.
5. Make rule fully blocking after baseline reaches acceptable size.
