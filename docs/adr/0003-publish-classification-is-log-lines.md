# Publish classification is emitted as log lines, not step outputs

The release classifies a failure as `published`, `deterministic`, `transient`, `resumable` or
`unknown` — the Portal helper for the Portal phases, a workflow step for the Gradle upload stage —
and prints the verdict as `RELEASE_PUBLISH_CLASS` / `RELEASE_PUBLISH_RETRYABLE` markers in the log
rather than as step outputs. Step outputs of a reusable workflow are unreliable
on failed runs — and a classification exists precisely to describe a failed run, so the mechanism
would be missing exactly when it is needed (#166, 2026-07-25).

## Consequences

Anything consuming the verdict has to scrape the log, including the TeamCity poller. Renaming a
marker or changing a class name is therefore a breaking change for consumers, with nothing at the
contract level to signal it — the values are effectively public API.
