# Octopus Tech Debt Register

This file tracks known technical debt items with stable IDs referenced from code comments.

## Open Items

| ID | Area | Location | Description | Next step |
| --- | --- | --- | --- | --- |
| TD-001 | example area | `path/to/file.kt` | Short description of debt. | Planned cleanup action. |
| TD-002 | release CI | `.github/workflows/common-java-maven-build.yml` | A transient upstream transfer failure fails a required check. The Maven build now retries the whole `mvn` process once when the log carries a transfer signature — Maven's own retry cannot reach this class: on the Maven the `ubuntu-latest` image ships (3.9.x) the wagon properties are inert, because 3.9.0 moved the default to the native transport; that transport's retry count defaults to 3 (`aether.connector.http.retryHandler.count` under Resolver 1.9.x, renamed `aether.transport.http.retryHandler.count` in 2.x) from Maven **3.9.1** onward — 3.9.0 shipped resolver 1.9.4 and retried nothing; and that count goes to HttpClient's `StandardHttpRequestRetryHandler`, which inherits `DefaultHttpRequestRetryHandler`'s five nonRetriableClasses — `SSLException` among them, matched by `isInstance` — and `bad_record_mac` is an `SSLException`. The exposure is not closed: the Gradle builds, the Sonatype publish and the `mvn deploy` in `common-java-maven-release.yml` have no equivalent, and retrying an *upload* mid-publish is a different risk class that has not been thought through. Observed 2026-08-31 as `bad_record_mac` from Maven Central, which reddened the octopus-test canary and blocked octopus-base#205. | Decide per transport whether a retry is safe, starting with the release path, where the same blip costs a release rather than a build. A retry that fires often is a signal to look at the transport, not to raise the count — every retry is announced for that reason. |
| TD-003 | quality plugin tests | `gradle-quality-plugin/build.gradle.kts` (`jvmToolchain(11)`); ErrorProne cases in `OctopusQualityPluginFunctionalTest.kt` | The ErrorProne functional tests only ever exercise JDK 11. `kotlin { jvmToolchain(11) }` sets the java toolchain for `Test` as well, and the TestKit daemon inherits the test JVM, so the forked-compiler path every consumer above JDK 16 takes — the nine `--add-exports` and two `--add-opens` flags injected by `ErrorProneJvmArgumentProvider` — never runs in CI. The bind is deliberate but self-reinforcing: the engine is pinned to 2.31.0, the last Java 11 bytecode release, *so that* these tests can execute the analyser rather than only inspect the task graph, which means the suite cannot move to a newer JDK without moving the pin. JDK 21 and 25 were verified by hand against a mavenLocal publish during the change; that check leaves no artifact and guards nothing against regression. Note the untested code belongs to `net.ltgt.errorprone`, not to this plugin — `configureErrorProne` deliberately configures no forking. | Take it up when the first consumer opts in (octopus-components-registry-service, JDK 21), which exercises the path on every build of that repo, or when the pin has to move for a JDK 24+ consumer — whichever comes first. The fix is a fixture-level toolchain on one test plus JDK 21 alongside 17 in this repo's own build job, pointed at with `-Porg.gradle.java.installations.fromEnv=JAVA_HOME_21_X64`. It was not done now because it is a CI-only path that cannot be validated locally, and this repo's merge gate is shared — `octopus-test`'s canary consumes the same workflow. |

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
