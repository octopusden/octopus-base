#!/usr/bin/env python3
"""Refuse a Central upload that would carry files Central does not need.

Usage: check-central-checksums.py <check-dir> <expected-dir>
  <check-dir>     a file:// repository the Central publications were just published into, with
                  -Dorg.gradle.internal.publish.checksums.insecure=true;
  <expected-dir>  the publication guard's routed local repository from the same run.
Either may be missing: Gradle creates neither when every publication is routed away.

Allowed in <check-dir>: each expected artifact file f with f.md5, f.sha1, f.asc, f.asc.md5 and
f.asc.sha1, and maven-metadata.xml with its .md5 and .sha1. Every expected f must be there too.
Exit 1 on an extra file (deterministic) or a missing f (unknown: the check did not run for it).
See "Checksum files" in docs/Octopus Release Pipeline.md.

Covered by .github/scripts/test/central-checksum-scenarios.sh and central-checksum-fixture.sh.
"""
import sys
from pathlib import Path

SIDECARS = ("", ".md5", ".sha1", ".asc", ".asc.md5", ".asc.sha1")
METADATA = ("maven-metadata.xml", "maven-metadata.xml.md5", "maven-metadata.xml.sha1")


def files_under(d):
    return sorted(p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file()) if d.is_dir() else []


def fail(cls, title, items, message):
    print(f"RELEASE_PUBLISH_CLASS={cls}")
    print("RELEASE_PUBLISH_RETRYABLE=false")
    for p in items:
        print(f"::error title={title}::{p} {message}")
    sys.exit(1)


check_dir, expected_dir = Path(sys.argv[1]), Path(sys.argv[2])
present = files_under(check_dir)
artifacts = [p for p in files_under(expected_dir)
             if not p.endswith((".md5", ".sha1", ".sha256", ".sha512", ".asc"))
             and not p.rsplit("/", 1)[-1].startswith("maven-metadata")]
allowed = {f + s for f in artifacts for s in SIDECARS}
extra = [p for p in present if p not in allowed and p.rsplit("/", 1)[-1] not in METADATA]
# A build that skips publish tasks by repository name leaves the check with nothing to judge.
missing = [f for f in artifacts if f not in present]

print("::group::Files this release would upload to Maven Central")
for p in present:
    print(f"  {p}")
print("::endgroup::")
print(f"{len(present)} files for {len(artifacts)} artifact files")

if extra:
    fail("deterministic", "Extra file for Maven Central", extra,
         "would be uploaded, and Central does not need it. Nothing was staged, so re-running after the fix is safe.")
if missing:
    fail("unknown", "Central checksum check saw nothing", missing,
         "was not published to the check repository, so its files were not checked. "
         "Does the build skip publish tasks by repository name?")
print("OK: no extra files.")
