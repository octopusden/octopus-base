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
- Java-heavy repositories: `checkstyle`, `pmd`, `spotbugs`, `jacoco`
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
// Java/Groovy modules need NO extra apply — the convention plugin
// auto-applies checkstyle, pmd, spotbugs, codenarc based on source dirs.

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
| Kotlin | detekt + ktlint + checkstyle + pmd + spotbugs | Kover (consumer applies kover plugin) |
| Java | checkstyle + pmd + spotbugs | JaCoCo (plugin applies jacoco) |
| Groovy | codenarc + checkstyle + pmd + spotbugs | JaCoCo (plugin applies jacoco) |
| Mixed | All applicable | JaCoCo |

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
