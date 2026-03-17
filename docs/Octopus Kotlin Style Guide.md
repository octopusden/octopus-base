# Octopus Kotlin Style Guide

This document defines Kotlin-focused style rules and examples for repositories using `detekt` and `ktlint`.

## Scope

- `detekt` configuration is repository-specific.
- `ktlint` configuration is repository-specific (`.editorconfig`).
- Baselines are allowed only for existing violations.
- Use `TD-xxx` references and `docs/Octopus Tech Debt Register.md` for deferred cleanup.

## Ktlint Rules

### `ktlint:standard:chain-method-continuation`

In multiline call chains, place a newline before `.`.

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

Wrap multiline class and constructor signatures consistently.

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

File must end with one trailing newline.

### `ktlint:standard:function-expression-body`

Prefer expression bodies for single-expression functions.

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

### `ktlint:standard:binary-expression-wrapping`

Wrap long binary expressions consistently.

Wrong:

```kotlin
val allowed = isEnabled &&
user.isActive && user.hasRole("ADMIN")
```

Right:

```kotlin
val allowed =
    isEnabled &&
        user.isActive &&
        user.hasRole("ADMIN")
```

### `ktlint:standard:string-template-indent`

Keep indentation consistent in multiline string templates.

Wrong:

```kotlin
val message = """
    Build: ${buildId}
  Status: ${status}
""".trimIndent()
```

Right:

```kotlin
val message = """
    Build: ${buildId}
    Status: ${status}
""".trimIndent()
```

### `ktlint:standard:max-line-length`

Use repository-configured `max_line_length` (for example, `140`) consistently.

Wrong:

```kotlin
val longMessage = "This line is intentionally too long ... (more than configured max length) ... to illustrate max-line-length violation"
```

Right:

```kotlin
val longMessage =
    "This line is split " +
        "to keep each line length below the configured maximum."
```

### `ktlint:standard:function-literal`

Use consistent multiline lambda formatting.

Wrong:

```kotlin
val names = values.map({
    it.name
})
```

Right:

```kotlin
val names =
    values.map {
        it.name
    }
```

### `ktlint:standard:argument-list-wrapping`

Wrap long argument lists when calls span multiple lines.

Wrong:

```kotlin
client.createMandatoryUpdate(dryRun, component, version, projectKey, epicName, dueDate, notice, customer)
```

Right:

```kotlin
client.createMandatoryUpdate(
    dryRun,
    component,
    version,
    projectKey,
    epicName,
    dueDate,
    notice,
    customer,
)
```

### `ktlint:standard:block-comment-initial-star-alignment`

Align leading `*` in block comments.

Wrong:

```kotlin
/*
* first line
  * second line
 */
```

Right:

```kotlin
/*
 * first line
 * second line
 */
```

## Detekt Rules

### `detekt:style:ClassOrdering`

Place `companion object` at the end of class body.

Wrong:

```kotlin
class VelocityEngine {
    companion object { ... }
    fun generate(...) = ...
}
```

Right:

```kotlin
class VelocityEngine {
    fun generate(...) = ...

    companion object { ... }
}
```

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

Do not use `TODO`, `FIXME`, or `STOPSHIP` in committed code without tracking.
Use `TD-xxx` with a link to the tech debt register.

Wrong:

```kotlin
// TODO: remove after release
```

Right:

```kotlin
// TD-002: switch to stable API after client migration (see docs/Octopus Tech Debt Register.md).
```

### `detekt:style:UseCheckOrError`

Prefer `require`, `check`, or `error` for guard conditions.

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

Do not keep unused private functions or properties.

### `detekt:exceptions:TooGenericExceptionCaught`

Catch the narrowest exception type that you can handle.

### `detekt:exceptions:SwallowedException`

Do not ignore exceptions silently. Handle with context, log, or rethrow.

## Baseline Strategy

1. Enable new rules in report mode first.
2. Capture baseline for existing violations.
3. Keep new code clean without adding baseline entries.
4. Burn down baseline gradually with tracked `TD-xxx` tasks.
