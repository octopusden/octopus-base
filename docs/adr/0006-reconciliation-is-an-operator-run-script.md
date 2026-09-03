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
  in the decision logic can cause a wrong write. The script's answer is that every write is guarded
  by a read-back and the plan is the default: `--apply` is a separate, deliberate invocation that
  re-reads everything first.
- **No allowlist.** A typo in the repository argument is caught by the commit lookup and by Central,
  not by a declared list. The blast radius is the operator's own access, which is wider than any
  token that would have been provisioned.
- **No concurrency control.** Two operators reconciling the same version at once are serialised only
  by the release log's compare-and-swap. The tag and the release are idempotent, so the exposure is
  a duplicated effort, not a corrupted state.
- **No run in Actions, in either repository.** There is no `environment: Prod`, no approval gate, and
  no automatic record that this happened. The GitHub Release and the release-log commit are
  attributed to the operator; the tag is a lightweight ref and has no author at all. The run's own
  report is printed and not stored.

One assumption is not verifiable from this repository: that internal release post-processing
triggers on a **commit** to `octopus-release-log`, and therefore reacts to a direct write exactly as
it reacts to the dispatch path's commit. The evidence for it is
`common-register-release.yml`'s own note that "each release-log entry is a commit that triggers
downstream post-processing, so registering twice runs that twice", plus the observed behaviour of
manual repairs in August 2026. It matters only when the recovered version becomes the file's first
line; when it is inserted below, post-processing is expected to run and stop at its own
"release version is new" check. Confirming it against the canary is a prerequisite for merging, and
the result belongs in this file.
