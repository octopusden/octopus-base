# An artifact's destination follows how it is obtained

Maven Central is for artifacts other projects **depend on**. Everything else a release produces —
a shadow jar, an executable application jar, a plugin bundle — is a *distribution*: something a
build step, a script or a person fetches and runs. Distributions had been going to Central anyway,
because that was the only place a release knew how to publish, and one of them can spend more of
the organisation's monthly Central budget than every genuine library combined.

So the destination is chosen not by what an artifact is called or how large it is, but by **how
anyone obtains it**: a dependency library belongs on Maven Central; a distribution resolved by
Maven coordinates belongs in GitHub Packages, where it keeps its coordinates and spends no Central
quota; a distribution downloaded from a URL belongs in a release asset; a distribution nobody
obtains should not be published at all.

Two rules follow. A **recognized executable artifact cannot be excepted back onto Central** — it
has a destination now, so an exception would only re-create the problem. And **only a genuine
dependency that is legitimately large may take a size exception**: size is a property of
libraries, not a category of its own.

## Consequences

Those two exceptions had been one switch, which is why this is recorded rather than merely
implemented. One allowlist waived "this is not a library" and "this library is big" together, and
because it was keyed by artifactId — which a module's thin and fat jars share — exempting the fat
jar also stopped the guard checking the thin one. An exception meant to admit one artifact
silently withdrew the check from another.

Splitting it cannot be done by renaming: the exception that waives size must be **unable** to
admit an executable artifact, or the policy is advisory.

Enforcement is staged. Five repositories relied on the combined switch when this was written —
four for shadow jars a metarunner fetches, one for a plugin bundle nothing resolves — and none for
a large library, so the narrow size exception begins with no legitimate user. Until those five
have somewhere to go, removing the bypass would break them; it is deprecated and warns first.

The policy also cannot be fully enforced by inspection, deliberately. A shadow jar published with
its classifier stripped carries no marker a rule can rely on, and the only available signals — an
executable manifest entry, a count of bundled third-party packages — are things ordinary libraries
also have. That shape is reported, not refused: refusing on a heuristic would trade a real failure
for a possible one at the moment a release can least absorb it, and Central versions are immutable.
