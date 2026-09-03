# Octopus Tech Debt Register

This file tracks known technical debt items with stable IDs referenced from code comments.

## Open Items

| ID | Area | Location | Description | Next step |
| --- | --- | --- | --- | --- |
| TD-001 | example area | `path/to/file.kt` | Short description of debt. | Planned cleanup action. |
| TD-002 | release CI | `.github/workflows/common-java-maven-build.yml` | A transient upstream transfer failure fails a required check. The Maven build now retries the whole `mvn` process once when the log carries a transfer signature — Maven's own retry cannot reach this class: on the Maven the `ubuntu-latest` image ships (3.9.x) the wagon properties are inert, because 3.9.0 moved the default to the native transport; that transport's retry count defaults to 3 (`aether.connector.http.retryHandler.count` under Resolver 1.9.x, renamed `aether.transport.http.retryHandler.count` in 2.x) from Maven **3.9.1** onward — 3.9.0 shipped resolver 1.9.4 and retried nothing; and that count goes to HttpClient's `StandardHttpRequestRetryHandler`, which inherits `DefaultHttpRequestRetryHandler`'s five nonRetriableClasses — `SSLException` among them, matched by `isInstance` — and `bad_record_mac` is an `SSLException`. The exposure is not closed: the Gradle builds, the Sonatype publish and the `mvn deploy` in `common-java-maven-release.yml` have no equivalent, and retrying an *upload* mid-publish is a different risk class that has not been thought through. Observed 2026-08-31 as `bad_record_mac` from Maven Central, which reddened the octopus-test canary and blocked octopus-base#205. | Decide per transport whether a retry is safe, starting with the release path, where the same blip costs a release rather than a build. A retry that fires often is a signal to look at the transport, not to raise the count — every retry is announced for that reason. |
| TD-003 | release | `.github/scripts/inspect-publication-set.py` | `fat-jar-publication-allowlist` still lets a recognized executable artifact onto Maven Central. It waives both of the guard's complaints at once and is keyed by artifactId — which a module's thin and fat jars share — so an exception admitting the fat jar also stops the guard checking the thin one. Kept working, and warning, only until consumers have somewhere else to send those artifacts. | Migrate the five consumers to `github-packages-publications` (or `oversize-library-allowlist` where the artifact really is a large library), then remove the executable-artifact bypass. Blocked on the `read:packages` credential for the TeamCity agents. See `docs/adr/0005-artifact-destination-follows-how-it-is-obtained.md`. |

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
