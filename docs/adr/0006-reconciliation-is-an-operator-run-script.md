# The #189 reconciliation is a script an operator runs, not a workflow

Completing the record of a published-but-unrecorded release (#189) is done by
`.github/scripts/recover-release.sh`, run from an `octopus-base` checkout under the operator's own
`gh` credential. The alternative was designed first and rejected: a `workflow_dispatch` workflow in
`octopus-base`, with an allowlist of recoverable repositories and two provisioned cross-repository
tokens, one read-only for the phase that decides and one writing for the phase that acts.

What decided it was where the cost falls. The event happens about monthly and is handled by one or
two administrators who already have write access to every repository involved. A central workflow
would add two permanent organisation-wide credentials, an allowlist that has to be extended before
each new component's first release, and a second design to keep in step with the release path —
against a reconciler that is only ever run deliberately, by a person, during an incident.

There is also one thing only the operator's credential can do. Creating a tag on a commit that
touches `.github/workflows` requires `workflow` scope (#180). The Actions `GITHUB_TOKEN` can never
carry it, and a release regularly builds such a commit; the token `gh auth login` mints does carry
it. The troubleshooting guide described this credential as one the organisation does not provision.
It does not need to: the operator already has it.

## Consequences

Four properties of the workflow design are given up, and they are real:

- **One credential instead of two.** The phase that decides now holds write capability, so a defect
  in the decision logic can cause a wrong write. The script's answer is that the plan is the
  default — `--apply` is a separate, deliberate invocation that re-reads everything first — and
  that every write is confirmed before the next one begins: the tag by resolving it, the release by
  reading it back, and the release-log entry from the write's own response rather than a later read,
  because a read straight after a write can be served from cache.
- **No allowlist.** A typo in the repository argument is caught by the commit lookup and by Central,
  not by a declared list. The blast radius is the operator's own access, which is wider than any
  token that would have been provisioned.
- **No concurrency control.** Two operators reconciling the same version at once are serialised only
  by the release log's compare-and-swap. The tag and the release are idempotent, so the exposure is
  a duplicated effort, not a corrupted state.
- **No run in Actions, in either repository.** There is no `environment: Prod`, no approval gate, and
  no automatic record that this happened. The GitHub Release is attributed to the operator, and so is
  the release-log commit's author — its committer is deliberately the bot, for the reason
  [ADR 0005](0005-reconciliation-writes-the-release-log-directly.md) gives. The tag is a lightweight
  ref and has no author at all. The run's own report is printed and not stored.

The provenance the reconciler needs — which commit was built — moved from an uploaded artifact with
an explicit 90-day retention to an annotation on the run. Those are not the same mechanism, and
until 1 October 2026 they had different lifetimes; from that date runs, checks and statuses follow
the same Actions retention setting artifacts do. This organisation's setting is 90 days, so the two
match: measured from the `expires_at` of a fresh artifact, since the setting is not exposed through
the API. If it is ever lowered, this trade stops being free and the runbook's 90 days becomes wrong.

One assumption is not verifiable from this repository: that internal release post-processing
triggers on a **commit** to `octopus-release-log`, and therefore reacts to a direct write exactly as
it reacts to the dispatch path's commit. The evidence for it is
`common-register-release.yml`'s own note that "each release-log entry is a commit that triggers
downstream post-processing, so registering twice runs that twice", plus the observed behaviour of
manual repairs in August 2026. It matters only when the recovered version becomes the file's first
line; when it is inserted below, post-processing is expected to run and stop at its own
"release version is new" check — which is every #189 case seen so far, because a wedged version is
one the log has already moved past.

So the assumption gates one case, and that case is where it must be confirmed: **before the first
recovery of a version that becomes the file's first line**, run one against `octopus-test` and
check that internal post-processing ran for it. `release-gradle-github-packages.yml` in that
repository produces the input state — a real release with a tag and a GitHub Release and no log
entry — without spending anything on Central, because it publishes with `publish-to-nexus: false`.
The reconciler prints a line telling the operator to check exactly this whenever the version it
wrote became the first line. The result of that rehearsal belongs in this file; until it is here,
treat a newest-version recovery as unproven and a below-the-top one as covered by the reasoning
above.
