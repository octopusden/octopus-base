# Octopus Tech Debt Register

This file tracks known technical debt items with stable IDs referenced from code comments.

## Open Items

| ID | Area | Location | Description | Next step |
| --- | --- | --- | --- | --- |
| TD-001 | example area | `path/to/file.kt` | Short description of debt. | Planned cleanup action. |
| TD-002 | release CI | `.github/workflows/common-java-maven-build.yml` | A transient upstream transfer failure fails a required check. The Maven build now retries the whole `mvn` process once when the log carries a transfer signature — Maven's own retry cannot reach this class: on the Maven the `ubuntu-latest` image ships (3.9.x) the wagon properties are inert, because 3.9.0 moved the default to the native transport; that transport's retry count defaults to 3 (`aether.connector.http.retryHandler.count` under Resolver 1.9.x, renamed `aether.transport.http.retryHandler.count` in 2.x) from Maven **3.9.1** onward — 3.9.0 shipped resolver 1.9.4 and retried nothing; and that count goes to HttpClient's `StandardHttpRequestRetryHandler`, which inherits `DefaultHttpRequestRetryHandler`'s five nonRetriableClasses — `SSLException` among them, matched by `isInstance` — and `bad_record_mac` is an `SSLException`. The exposure is not closed: the Gradle builds, the Sonatype publish and the `mvn deploy` in `common-java-maven-release.yml` have no equivalent, and retrying an *upload* mid-publish is a different risk class that has not been thought through. Observed 2026-08-31 as `bad_record_mac` from Maven Central, which reddened the octopus-test canary and blocked octopus-base#205. | Decide per transport whether a retry is safe, starting with the release path, where the same blip costs a release rather than a build. A retry that fires often is a signal to look at the transport, not to raise the count — every retry is announced for that reason. |
| TD-003 | release CI | `.github/workflows/check-octopus-test-consumer.yml`, `octopusden/octopus-test` callers | The canary can be updated ahead of the contract it verifies, and then it blocks every unrelated PR. `octopus-test`'s `main` began passing `github-packages-publications` to `common-java-gradle-release.yml` on 2026-09-02 (octopus-test#55), while that input exists only on octopus-base's `add-github-packages-publish` branch (#207, `CHANGES_REQUESTED`). A caller passing an input the pinned reusable workflow does not declare fails at load time, so `consumer-verify` reports `startup_failure` for every PR except the one that carries the input — observed on #209. The verifier cannot tell this apart from a real contract regression: it reads a conclusion, and `startup_failure` and "the change broke the canary" look identical. The same shape blocked #205 for a different reason (see TD-002), so the cost recurs. | Make the skew visible before it is a red gate: have `consumer-verify` compare the inputs the canary's callers pass against those the pinned workflows declare, and say which side is ahead. Failing is fine; failing with `startup_failure` and no cause is what costs the time. The ordering rule itself belongs in `AGENTS.md`, which already says to keep the canary aligned with the current contract — it has no enforcement. |

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
