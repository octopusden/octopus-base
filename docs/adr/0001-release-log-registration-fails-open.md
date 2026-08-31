# Release-log registration fails open

The check that runs before registering a release — "is this version already in the release log?" —
cannot always reach a verdict: a component being released for the first time has no file in the
log at all, and the read can fail for ordinary reasons besides. When it cannot decide, it
registers anyway rather than blocking, because the two errors are not symmetric: a missing entry
stalls the release pipeline and has to be repaired by hand, while a duplicate entry only repeats
downstream bookkeeping.

## Consequences

The property has to hold on **every** path, not only inside the check's own logic. Anything that
can abort the step before it produces an answer defeats the decision just as thoroughly as a wrong
verdict would — a helper that cannot be fetched, a script that exits non-zero, a shell flag that
turns a survivable error into a fatal one.

This is recorded because it was learned expensively. The decision was made in #172 (2026-07-27)
and lived only as a comment inside the workflow step. The code beneath that comment contradicted
it: the step runs under `bash -e`, the comment asserted it did not, and the first lookup aborted
the whole step on the ordinary HTTP 404 for a component with no log file. Every new component's
first release therefore failed to register, for the entire time the comment claimed the opposite
(#196).
