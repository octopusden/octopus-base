#!/usr/bin/env python3
"""Refuse a Central upload that would carry files Central does not need.

Central counts every uploaded file against the org's monthly File Count, checksums included, and
needs only md5 + sha1 of each file. The upload runs with
-Dorg.gradle.internal.publish.checksums.insecure=true so that Gradle writes no sha256 or sha512. That
property is internal: a Gradle that ignores it writes them without any error. This check is the error.

Usage: check-central-checksums.py <check-dir> <expected-dir>
  <check-dir>     a file:// repository the release just published its Central publications into,
                  with the flag, through the same publisher the HTTP upload uses;
  <expected-dir>  the publication guard's routed local repository from the same run, which holds
                  every artifact file Central should receive (mavenLocal writes no checksums).
Either may be missing: Gradle creates neither when every publication is routed away.

The rule: every file in <check-dir> must be an expected artifact file f or one of f.md5, f.sha1,
f.asc, f.asc.md5, f.asc.sha1, or a maven-metadata.xml with its .md5 and .sha1. Anything else is an
extra file, most often a sha256/sha512 or a publication routed away from Central. What must be
present is not checked here: the Central Portal validates that, and portal-publish.sh classifies
its refusal.

Exit 0 = nothing extra; 1 = extra files (classified deterministic: nothing was staged).
Prints the full file list to the log.

Covered by .github/scripts/test/central-checksum-scenarios.sh and
.github/scripts/test/central-checksum-fixture.sh.
"""
import sys
from pathlib import Path

SIDECARS = ("", ".md5", ".sha1", ".asc", ".asc.md5", ".asc.sha1")
METADATA = ("maven-metadata.xml", "maven-metadata.xml.md5", "maven-metadata.xml.sha1")


def files_under(d):
    return sorted(p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file()) if d.is_dir() else []


check_dir, expected_dir = Path(sys.argv[1]), Path(sys.argv[2])
present = files_under(check_dir)
artifacts = [p for p in files_under(expected_dir)
             if not p.endswith((".md5", ".sha1", ".sha256", ".sha512", ".asc"))
             and not p.rsplit("/", 1)[-1].startswith("maven-metadata")]
allowed = {f + s for f in artifacts for s in SIDECARS}
extra = [p for p in present if p not in allowed and p.rsplit("/", 1)[-1] not in METADATA]

print("::group::Files this release would upload to Maven Central")
for p in present:
    print(f"  {p}")
print("::endgroup::")
print(f"{len(present)} files for {len(artifacts)} artifact files")

if extra:
    print("RELEASE_PUBLISH_CLASS=deterministic")
    print("RELEASE_PUBLISH_RETRYABLE=false")
    for p in extra:
        print(f"::error title=Extra file for Maven Central::{p} would be uploaded, and Central does not need it.")
    print(f"{len(extra)} extra file(s). Nothing was staged, so re-running after the fix is safe.")
    sys.exit(1)
print("OK: no extra files.")
