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

The `org.octopusden.octopus-quality` convention plugin (in `gradle-quality-plugin/`) auto-configures all quality tools listed above. Consumer repos apply one plugin and get `qualityStatic`, `qualityCoverage`, and `qualityCheck` tasks.

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
        id("org.octopusden.octopus-quality") version "<octopus-base-version>"
    }
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

// build.gradle.kts — apply at root:
plugins {
    kotlin("jvm") apply false
    id("io.gitlab.arturbosch.detekt") apply false
    id("org.jlleitschuh.gradle.ktlint") apply false
    id("org.octopusden.octopus-quality")
}

subprojects {
    apply(plugin = "org.jetbrains.kotlin.jvm")
    apply(plugin = "io.gitlab.arturbosch.detekt")
    apply(plugin = "org.jlleitschuh.gradle.ktlint")
}

// Optional overrides:
octopusQuality {
    coverage {
        enabled.set(false)                          // disable for repos without tests
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

> **Version ownership:** Consumer repos own the versions of Kotlin, detekt, and ktlint — declared in `pluginManagement` and pinned in `gradle.properties`. The convention plugin configures these tools (shared rules, baselines, reports) but does NOT pin their versions. This decouples tool version upgrades from the convention plugin release cycle.

### What the plugin auto-configures

| Language detected | Tools applied | Coverage |
|-------------------|---------------|----------|
| Kotlin | detekt + ktlint + checkstyle + pmd + spotbugs | Kover (if Kotlin-only) |
| Java | checkstyle + pmd + spotbugs | JaCoCo |
| Groovy | codenarc + checkstyle + pmd + spotbugs | JaCoCo |
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
