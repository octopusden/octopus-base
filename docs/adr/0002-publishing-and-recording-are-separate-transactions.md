# Publishing to Central and recording a release are separate transactions

A release does two things: it puts artifacts on Maven Central, and it records that it did — a git
tag, a GitHub Release, and a line in `octopus-release-log`. These cannot be one atomic operation,
because Central is immutable and third-party while the record is ours and rewritable. We gate the
recording on the publish having succeeded, rather than the other way round or not at all, because
recording a release that never published is worse than the reverse: it would advertise a version
nobody can resolve.

## Consequences

The gate makes one specific bad state reachable **by design**: a run that dies after the upload
leaves the version published, untagged and unregistered. The pipeline cannot repair that on its
own, and the next release computes the same version and is refused with `already exists` — which
is correct, because it is. Recovery is manual until something reconciles the two sides (#189).

Every deadline in the publish path inherits this. Giving up while Central is still `PUBLISHING`
does not stop the publish; it only stops us watching, and Central may finish minutes later
(#193). That is why such a failure is classified `resumable` and explicitly not retryable: a plain
re-run would upload a version that is already on its way.

The two halves therefore need separate names, and the
[pipeline reference](../Octopus%20Release%20Pipeline.md) gives them: a *deployment state* belongs
to Sonatype, a *release state* is ours and is four independent facts rather than one value.
