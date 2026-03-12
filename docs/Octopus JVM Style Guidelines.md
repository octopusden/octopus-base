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

## Kotlin Rule Examples

### `ktlint:standard:chain-method-continuation`

Use multiline call chains with dots at line starts.

Wrong:
```kotlin
val value = source.map { it.id }.filter { it > 0 }
```

Right:
```kotlin
val value =
    source
        .map { it.id }
        .filter { it > 0 }
```

### `ktlint:standard:class-signature`

Wrap multiline class/constructor signatures consistently.

Wrong:
```kotlin
data class CommitDTO(val id: String, val author: String, val message: String)
```

Right:
```kotlin
data class CommitDTO(
    val id: String,
    val author: String,
    val message: String,
)
```

### `ktlint:standard:final-newline`

File must end with a single trailing newline.

### `ktlint:standard:function-expression-body`

Prefer expression body for single-expression functions.

Wrong:
```kotlin
fun isEmpty(value: String): Boolean {
    return value.isEmpty()
}
```

Right:
```kotlin
fun isEmpty(value: String): Boolean = value.isEmpty()
```

### `ktlint:standard:argument-list-wrapping`

Wrap long argument lists when a call spans multiple lines.

### `detekt:style:ClassOrdering`

Place `companion object` at the end of class body.

### `detekt:style:WildcardImport`

Do not use wildcard imports.

Wrong:
```kotlin
import org.example.dto.*
```

Right:
```kotlin
import org.example.dto.BuildDTO
import org.example.dto.BuildFilterDTO
```

### `detekt:style:ForbiddenComment`

Do not leave `TODO/FIXME/STOPSHIP` in code without tracking. Use `TD-xxx` and link to tech debt register.

Wrong:
```kotlin
// TODO: remove after release
```

Right:
```kotlin
// TD-002: remove fallback API call after client migration (see docs/Octopus Tech Debt Register.md).
```

### `detekt:style:UseCheckOrError`

Prefer `require/check/error` for guard conditions.

Wrong:
```kotlin
if (prop == null) {
    throw IllegalStateException("Property must be provided")
}
```

Right:
```kotlin
check(prop != null) { "Property must be provided" }
```

### `detekt:style:UnusedPrivateMember` and `detekt:style:UnusedPrivateProperty`

Do not keep unused private members/properties.

### `detekt:exceptions:TooGenericExceptionCaught`

Catch the narrowest exception type that can be handled.

### `detekt:style:SwallowedException`

Do not silently ignore exceptions. Handle, log with context, or rethrow.

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
