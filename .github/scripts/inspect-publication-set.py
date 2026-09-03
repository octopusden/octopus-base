#!/usr/bin/env python3
"""Inspect the publication set a release would upload to Maven Central, before it uploads.

Reads a local Maven repository that `publishToMavenLocal` has just written, and refuses the
release when it would publish something Central should not receive. Two independent refusals:

  * a version other than the release version — most often Gradle's `unspecified`, when the
    version properties never reached that project. A release publishes exactly one version,
    and Central keeps whatever it is handed forever;
  * an artifact unfit for Central as a dependency — a shadow/uber jar, a Spring Boot
    executable jar, or anything over the size limit.

The version refusal is also made later, by the Portal publish step — but only after
everything has been built, signed and uploaded, leaving a staging repository to drop by hand.
This is the same judgement, before the upload. Both are kept: that one sees what the deployment
being published contains, which differs from what this build produced when
resume-deployment-id names another deployment.

Usage: inspect-publication-set.py <local-repo-dir>
Env: BUILD_VERSION, FAT_JAR_ALLOWLIST, MAX_ARTIFACT_MB, DRY_RUN
     DRY_RUN=true downgrades the version refusal from exit 1 to exit 0 (a warning); the
     fat-jar refusals are unaffected and still exit 1. A direct caller that omits it gets
     the strict behaviour, which is the safe default.
Exit 0 = the set is fit to upload, 1 = it is not.

Covered by .github/scripts/test/publication-set-scenarios.sh.
"""
import os, re, sys, zipfile
from pathlib import Path

repo = Path(sys.argv[1])
allowed = {a.strip() for a in os.environ.get("FAT_JAR_ALLOWLIST", "").split(",") if a.strip()}
max_mb = float(os.environ.get("MAX_ARTIFACT_MB") or 8)
release_version = os.environ.get("BUILD_VERSION", "").strip()
# A dry run publishes nothing, so there is no upload for this refusal to save and no reason for
# it to fail. That is not symmetry for its own sake: consumer repositories run a dry release as
# a required merge check, and the fat-jar rules below have always run there — so those are
# already green everywhere, while a NEW refusal firing under dry-run would turn a green required
# check red on nothing but an octopus-base ref bump, with no Portal step afterwards to refuse
# the upload the argument for this check rests on.
dry_run = os.environ.get("DRY_RUN", "").strip().lower() == "true"

publications, published, offenders, wrong_version = [], [], [], []
archived = set()

# Publications are enumerated from their POMs, not from the archives below. Every Maven
# publication writes a POM whether or not it has an archive, so this is the only enumeration
# that sees a POM-only publication such as a BOM — which the archive glob would miss, letting
# a BOM at the wrong version through to the upload. The glob answers a different question:
# whether an artifact is fit for Central at all.
for pom in sorted(repo.rglob("*.pom")):
    version = pom.parent.name
    try:
        coordinate = "{}:{}".format(
            str(pom.parent.parent.parent.relative_to(repo)).replace("/", "."),
            pom.parent.parent.name,
        )
    except ValueError:
        # A POM shallower than <group>/<artifactId>/<version>/ is not a publication — a
        # `publishToMavenLocal` into a throwaway repository does not produce one, but a
        # traceback here would replace this step's whole point, which is naming the situation
        # and its remedy.
        print(f"::warning title=Unrecognised file in the publication set::{pom} is not laid out "
              "as <group>/<artifactId>/<version>/, so it is not a publication and was skipped.",
              flush=True)
        continue
    # A release publishes ONE version. Any other — most often Gradle's `unspecified`, when the
    # version properties never reached that project — is a build defect, and Central keeps
    # whatever it is handed forever.
    publications.append((coordinate, version))
    if release_version and version != release_version:
        wrong_version.append((coordinate, version))

# .zip is included because automation modules can publish shadow distributions and
# TeamCity plugin bundles, which cost the same quota as a jar.
for path in sorted(p for ext in ("*.jar", "*.zip", "*.tar", "*.tar.gz") for p in repo.rglob(ext)):
    # <group path>/<artifactId>/<version>/<file>
    artifact_id = path.parent.parent.name
    size_mb = path.stat().st_size / 1048576
    published.append((artifact_id, path.name, size_mb))
    # Keyed by coordinate AND version, not by artifactId: the same artifactId can appear at two
    # versions in one local repository, and matching on the name alone then hides the
    # POM-only line for the version that has no archive.
    archived.add((
        "{}:{}".format(str(path.parent.parent.parent.relative_to(repo)).replace("/", "."), artifact_id),
        path.parent.name,
    ))
    reasons = []
    # Covers both the jar and the shadow distribution archive (-all.zip/-all.tar).
    if re.search(r"-all\.(jar|zip|tar(\.gz)?)$", path.name):
        reasons.append("shadow/uber artifact (-all classifier)")
    else:
        try:
            with zipfile.ZipFile(path) as z:
                if any(n.startswith("BOOT-INF/") for n in z.namelist()):
                    reasons.append("Spring Boot executable jar (BOOT-INF/)")
        except zipfile.BadZipFile:
            pass
    # Size is the signal that catches what the markers miss — e.g. a shadow jar
    # published with the classifier stripped, which is indistinguishable from a
    # library jar by name and has no BOOT-INF/ either.
    if size_mb > max_mb:
        reasons.append(f"exceeds {max_mb:g} MB")
    if reasons and artifact_id not in allowed:
        offenders.append((artifact_id, path.name, size_mb, "; ".join(reasons)))

# "Nothing to inspect" means no POM either. A publication with no archive is a normal,
# checked publication — a BOM, or the marker java-gradle-plugin creates — and its version has
# been compared above, so reporting the set as unchecked because the archive glob found
# nothing would be false, and would hide the very case this enumeration was rewritten for.
if not publications and not published:
    print(
        "::warning title=Nothing to inspect::The publication set is empty, so nothing was "
        "checked. This step only runs when the repository is supposed to publish to Maven "
        "Central, so an empty set means the build produced no publication — or produced it "
        "somewhere other than the inspected repository.",
        flush=True,
    )

print(f"Enumerated {len(publications)} publication(s) from their POMs and inspected "
      f"{len(published)} archive(s) that would be published to Maven Central "
      f"at version {release_version or '(unknown)'} (size limit {max_mb:g} MB):")
for coordinate, version in publications:
    if (coordinate, version) not in archived:
        print(f"  {coordinate:<45} {'(no archive: POM-only publication)':<55} {version}")
for artifact_id, name, size_mb in published:
    print(f"  {artifact_id:<45} {name:<55} {size_mb:7.2f} MB")
if allowed:
    print(f"Explicitly allowed: {', '.join(sorted(allowed))}")

if wrong_version:
    level, verb = ("warning", "would be") if dry_run else ("error", "would be")
    print(f"\n::{level}::Artifact(s) {verb} published at a version other than {release_version}", flush=True)
    for coordinate, version in sorted(set(wrong_version)):
        print(f"  {coordinate} carries version '{version}'", file=sys.stderr)
    print(
        f"\nThis release is {release_version}, and a release publishes exactly one version. "
        "`unspecified` is Gradle's value when nothing set one, so a publication carrying it never "
        "received the version properties: set the version for every project that declares a "
        "publication, or stop publishing the module.",
        file=sys.stderr,
    )
    if not dry_run:
        sys.exit(1)
    print("(dry run — a real release would stop here.)")

if offenders:
    print("\n::error::Artifact(s) unfit for Maven Central would be published", flush=True)
    for artifact_id, name, size_mb, reason in offenders:
        print(f"  {artifact_id}: {name} ({size_mb:.2f} MB) — {reason}", file=sys.stderr)
    print(
        "\nCentral is for artifacts consumed as a Maven dependency. Either stop publishing "
        "this module (declare no MavenPublication for it, or set publish-to-nexus: false for "
        "a repository nobody consumes), or — if a consumer really resolves this artifact from "
        "a Maven repository, e.g. a TeamCity metarunner — add its artifactId to the "
        "fat-jar-publication-allowlist input with that justification. Raise "
        "max-central-artifact-mb only if a genuinely consumed library is legitimately large.",
        file=sys.stderr,
    )
    sys.exit(1)
if wrong_version:
    # Reached only in a dry run; a real release exited above.
    print("\nPublication set is NOT fit for Maven Central: a real release stops on the "
          "version(s) above. This run continues only because it is a dry run.")
else:
    print("\nPublication set is fit for Maven Central.")
