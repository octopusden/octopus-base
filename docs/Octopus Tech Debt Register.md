# Octopus Tech Debt Register

This file tracks known technical debt items with stable IDs referenced from code comments.

## Open Items

| ID | Area | Location | Description | Next step |
| --- | --- | --- | --- | --- |
| TD-001 | release | `.github/workflows/common-java-gradle-release.yml` | `fat-jar-publication-allowlist` still lets a recognized executable artifact onto Maven Central. It waives both of the guard's complaints at once and is keyed by artifactId — which a module's thin and fat jars share — so an exception admitting the fat jar also stops the guard checking the thin one. Kept working, and warning, only until consumers have somewhere else to send those artifacts. | Migrate the five consumers to `github-packages-publications` (or `oversize-library-allowlist` where the artifact really is a large library), then remove the executable-artifact bypass. Blocked on the `read:packages` credential for the TeamCity agents. See `docs/adr/0005-artifact-destination-follows-how-it-is-obtained.md`. |

## Closed Items

Move resolved records here to keep history.

| ID | Area | Location | Description | Resolution |
| --- | --- | --- | --- | --- |

## How To Reference In Code

Use `TD-xxx` in comments and point to this file.

Example:

```kotlin
// TD-001: remove temporary fallback after migration (see docs/Octopus Tech Debt Register.md).
```
