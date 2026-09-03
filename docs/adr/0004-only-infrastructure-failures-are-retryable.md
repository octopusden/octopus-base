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
re-runs plainly gets `already exists` and a component whose record then has to be completed by
`.github/scripts/recover-release.sh`, which is what happened to `octopus-sonar-automation` 2.0.15
(#189).

The resume path itself has a defect worth knowing about while using it: the job that creates the
tag takes the commit from the run doing the resuming, not from the run that built the artifacts, so
a branch that moved in between gets tagged at the wrong commit. Both the Gradle flow and
`octopus-base`'s own release now annotate the resumed run to say its HEAD is not the published
commit, but the annotation only warns — the tagging job is unchanged, and fixing it needs a way to
pass the original commit in, which `target-ref` cannot express today.

The default for anything unclassified is therefore also non-retryable: without evidence, "a retry
cannot help" is the answer that cannot make things worse.
