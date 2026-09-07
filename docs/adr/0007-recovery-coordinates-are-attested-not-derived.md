# The coordinates a recovery checks are attested by the operator, not derived

Before completing the record of a published version (#189), the reconciler asks Maven Central
whether that version is really there — and it can only ask about coordinates it has been given. The
operator passes them on the command line. Nothing derives them.

The obvious alternative was designed and removed: run the recovered repository's own build to list
its publications. It would mean executing an arbitrary consumer's build configuration in the same
context as a credential that can write to every release repository, and it buys only the case where
the operator cannot read the coordinates out of the failed run's log — which they can, in all three
flows:

- a Gradle release prints them in the Central preflight block, `Publications this release would
  publish`, before the build. Not on a resumed run: the preflight is skipped there, and the
  coordinates are in the log of the run that actually published.
- a Maven release has no preflight at all. Its `mvn deploy` output names each artifact it uploaded
  in its `Uploading to` lines.
- `octopus-base`'s own release prints a `Deployment coordinates` block from the Portal helper.

Parsing a `pom.xml` instead was also rejected. An inherited `groupId` and a multi-module build both
make the text of a POM a poor answer to "what was published", and a wrong answer here is a recovery
that confirms the wrong artifacts.

## Consequences

The list is only as complete as the operator makes it. A coordinate they forget is a coordinate
never checked, so the check is weaker than it looks: it proves that what was named is on Central,
not that nothing else was published. That is accepted, because the failure it guards against is the
opposite one — recovering a version that was never published at all.

Central's answer proves the artifacts exist. It cannot prove they were built from the commit the
operator named; nothing outside the run's own record can. The commit is an attestation too, so the
only thing the reconciler refuses on is a commit that does not exist in the repository at all. It
deliberately does not check whether the commit is reachable from the default branch: a
squash-merged release branch that has since been deleted leaves a legitimate commit that no branch
reaches, and the mistake such a check looks like it would catch — tagging the branch head instead
of the commit that was built, as nearly happened to octopus-cve-automation 2.0.3 — is precisely the
case where the branch head answers that it is reachable.

A partly published version — some coordinates present, some absent — is refused for both paths.
Central will not accept the missing ones alongside the ones that exist, so neither recovering nor
re-running that version can be right.
