# A reconciliation writes the release log directly, and may not fail open

Recording a release normally means a `repository_dispatch` to `octopus-release-log`, whose workflow
prepends the version to `<module>.txt`. A reconciliation of a version that published but was never
recorded (#189) does **not** use that path. It writes the file itself, through the Contents API,
inserting one line where the file's own ordering puts it, and it fails closed if it cannot.

Two reasons, and the first is not about credentials.

**The dispatch path can only prepend.** The first line of a module file is load-bearing: internal
release post-processing triggers on a commit to that repository, takes its build number from
`head -n 1 <module>.txt`, and refuses to run when its stored last-release value is already at least
that. A reconciliation runs, by definition, on a version that is not always the newest — 2.0.15
while 2.0.16 has already shipped. Dispatching it would prepend a stale version, and post-processing
would then compute the wrong version until the next real release. That is worse than the missing
entry it set out to repair, and invisible to a presence check, which answers whether a version is
in the file and not where.

**A dispatch cannot be confirmed.** Its success means the event was accepted. The run that writes
the entry is a different run in another repository, and that is exactly how 2.0.15's registration
went missing while every visible step was green. A direct write returns the commit it made.

Those checks run on every read of the file, including the re-read after a compare-and-swap
conflict: whoever won that race may have written a line this would have refused to touch, and
retrying past it would write over exactly the state this refuses to write over.

Nothing outside the file's ordering is repaired. Existing adjacent duplicates — four module files
carry them, because the dispatch path prepends unconditionally and a repeated dispatch leaves two
identical lines — are reported and left alone. A file whose lines are out of order, or whose lines
are not versions at all, stops the write instead: repairing someone else's history is a separate
decision from recording this version.

## Consequences

This is the opposite of [ADR 0001](0001-release-log-registration-fails-open.md), and deliberately.
Failing open is right on the release path, where the alternative is blocking a release over
bookkeeping, and wrong in a reconciliation, where the bookkeeping *is* the deliverable.

The release log is also written **last**, after the tag and a non-draft release are confirmed. It is
the only one of the three ledgers with a consumer outside these repositories, and the release path
never shows that consumer a version whose tag and release are not already in place.

A direct write is made to look like the dispatch path's commit where that is observable: the same
`<module>-<version>` message and `github-actions[bot]` as **committer**, which are the two things a
trigger filter could distinguish. The **author** is left as the operator, so the commit still records
who did this — there is no run in Actions to record it instead. The internal post-processing behind
that trigger is not ours to inspect; see
[ADR 0006](0006-reconciliation-is-an-operator-run-script.md) for what that assumption rests on.
