# Octopus Tech Debt Register

This file tracks known technical debt items with stable IDs referenced from code comments.

## Open Items

| ID | Area | Location | Description | Next step |
| --- | --- | --- | --- | --- |
| TD-001 | example area | `path/to/file.kt` | Short description of debt. | Planned cleanup action. |
| TD-002 | release CI | `.github/workflows/common-java-maven-build.yml` | A transient upstream transfer failure fails a required check. The Maven build now retries HTTP transfers, but the exposure is not closed: the Gradle builds, the Sonatype publish and the `mvn deploy` in `common-java-maven-release.yml` have no equivalent, and retrying an *upload* mid-publish is a different risk class that has not been thought through. Observed 2026-08-31 as `bad_record_mac` from Maven Central, which reddened the octopus-test canary and blocked octopus-base#205. | Decide per transport whether a retry is safe, starting with the release path, where the same blip costs a release rather than a build. |

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
