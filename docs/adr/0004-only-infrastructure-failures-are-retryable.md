# Only unambiguous infrastructure failures are marked retryable

`RELEASE_PUBLISH_RETRYABLE=true` is asserted only on infrastructure signals — 5xx, timeout,
connection reset — seen **before** anything was staged. Everything else stays non-retryable, even
a publish that plainly did not happen, because the expensive mistake is not a wasted wait: Maven
Central refuses a coordinate that already exists, so an over-eager retry turns a recoverable run
into a wedged one.

## Consequences

`resumable` is the case that surprises people. It names a failure that *can* be finished — the
artifacts are staged, the deployment exists — and it is still `retryable=false`, because
finishing it means re-dispatching with `resume-deployment-id`, not re-running. An operator who
re-runs plainly gets `already exists` and a component that now needs a manual tag, which is what
happened to `octopus-sonar-automation` 2.0.15 (#189).

The default for anything unclassified is therefore also non-retryable: without evidence, "a retry
cannot help" is the answer that cannot make things worse.
