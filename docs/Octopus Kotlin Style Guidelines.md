# Octopus Kotlin Style Guidelines

This document defines common Kotlin style checks for Octopus services using `detekt` and `ktlint`.

## Scope

- `detekt` config: `config/detekt/detekt.yml`
- `ktlint` config: `.editorconfig`
- Baseline files: `*/detekt-baseline.xml`, `*/ktlint-baseline.xml`
- Technical debt references: `docs/Octopus Tech Debt Register.md`

## CI Quality Gate

Recommended CI tasks:

```bash
./gradlew qualityStatic
./gradlew qualityCoverage
```

Where:
- `qualityStatic` runs static checks (for example detekt/ktlint).
- `qualityCoverage` runs tests and coverage validation.

## Enabled Checks

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

## Default Thresholds To Review

If enabled for a repository, start with defaults and tune only when there is a clear reason:

- `detekt:complexity:LongMethod`
- `detekt:complexity:LongParameterList`
- `detekt:complexity:NestedBlockDepth`
- `detekt:style:MagicNumber`
- `detekt:style:ReturnCount`

## Baseline Strategy

- Baseline is allowed only for existing violations.
- New code must pass without introducing extra baseline entries.
- Every baseline item must have a cleanup plan if it is non-trivial.

## Recommended Review Process

1. Enable rule in warning/report mode.
2. Capture current baseline.
3. Fix new violations first.
4. Gradually burn down baseline items.
5. Make rule fully blocking after baseline reaches acceptable size.
