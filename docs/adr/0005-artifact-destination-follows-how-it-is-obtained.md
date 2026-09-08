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

Two rules follow. A **recognized executable artifact must not be excepted back onto Central** — it
has a destination now, so an exception would only re-create the problem. And **the size ceiling
admits no exception at all**: the quota is shared organisation-wide, so an artifact over it is
routed elsewhere whether or not it is a genuine dependency. A repository may set a stricter local
threshold; it may not raise one.

One deprecated bypass still admits an executable artifact, and warns; see Consequences.

## Consequences

Those two exceptions had been one switch, which is why this is recorded rather than merely
implemented. One allowlist waived "this is not a library" and "this library is big" together, and
because it was keyed by artifactId — which a module's thin and fat jars share — exempting the fat
jar also stopped the guard checking the thin one. An exception meant to admit one artifact
silently withdrew the check from another.

A size exception was considered and rejected. It is the more tempting of the two, because "a
genuine dependency that happens to be large" sounds like a category the guard should accommodate —
and an earlier revision of this ADR provided one. But a ceiling that any repository can except
itself from is not a ceiling, and the quota it protects belongs to every repository at once. The
destination rule already answers the case: something too large for Central is obtained the same
way, from somewhere else. What survives is a **stricter** local threshold, which cannot harm
anyone else.

Enforcement is staged, and the survey behind that is what makes this safe: every artifact then
held on Central by the combined switch was a distribution a build tool fetches by coordinates.
**None** was a large library — so refusing size exceptions takes nothing away from anyone who had
one. Removing the bypass outright would still break every repository on it, so it is deprecated
and warns first. Which repositories those are, and the order they move in, is rollout state and is
tracked outside this repository.

One shape the policy cannot recognise: a shadow jar published with its classifier stripped
occupies the unclassified `jar` slot and carries no marker a rule can rely on. Only the size limit
catches it, which is why a size exception must never be granted to one — the exception would
remove the single check that sees it. Detecting the shape itself was considered and left out: the
available signals (an executable manifest entry, a count of bundled packages) are things ordinary
libraries also have, so a rule built on them could refuse a valid release, and a warning that
changes no outcome is only noise.
