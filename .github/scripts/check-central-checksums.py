#!/usr/bin/env python3
"""Check the files a release would upload to Maven Central, before it uploads (octopus-base#238).

Central counts every uploaded file against the org's monthly File Count, checksums included, and
needs only md5 + sha1 of each file. The upload therefore runs with
-Dorg.gradle.internal.publish.checksums.insecure=true, which stops Gradle writing sha256 and
sha512. That property is internal and undocumented, so if Gradle stops honouring it the extra
files come back and nothing fails. This check is what fails.

Reads two directories:
  <check-dir>     a file:// repository the release just published its Central publications into,
                  with the flag, through the same publisher the HTTP upload uses;
  <expected-dir>  the publication guard's routed local repository from the same run, which lists
                  every file Central should receive (publishToMavenLocal writes no checksums, so it
                  cannot be the check directory itself).
and the Gradle version from <check-dir>.gradle-version, written by the check's init script: Gradle
9.7 stopped writing checksums of signatures.

Rules. For every artifact file f (anything but metadata, a signature or a checksum):
  * the check directory holds exactly the expected set of artifact files;
  * f.md5 and f.sha1 are present;
  * no *.sha256 or *.sha512 anywhere, maven-metadata.xml included;
  * CHECK_MODE=signed (a real upload): f.asc is present, and on Gradle 9.7 or later f.asc has no
    checksums. CHECK_MODE=unsigned (a dry run, which holds no key) skips the signature rules.

Env: CHECK_MODE=signed|unsigned (required). Prints the full file list to the log.
Exit 0 = fit to upload; 1 = a rule is broken (classified deterministic, nothing was staged);
2 = the input is unusable, which says nothing about the release and is not classified.

Covered by .github/scripts/test/central-checksum-scenarios.sh (the rules) and
.github/scripts/test/central-checksum-fixture.sh (what Gradle really writes).
"""
import os, re, sys
from pathlib import Path

CHECKSUMS = (".md5", ".sha1", ".sha256", ".sha512")
FORBIDDEN = (".sha256", ".sha512")


def unusable(msg):
    print(f"::error title=Central checksum check could not run::{msg}", flush=True)
    sys.exit(2)


def files_under(d):
    return {p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file()}


def base(path):
    """The file a checksum belongs to, or the path itself."""
    for ext in CHECKSUMS:
        if path.endswith(ext):
            return path[: -len(ext)]
    return path


def is_artifact(path):
    name = path.rsplit("/", 1)[-1]
    return base(path) == path and not path.endswith(".asc") and not name.startswith("maven-metadata")


if len(sys.argv) != 3:
    unusable("usage: check-central-checksums.py <check-dir> <expected-dir>")
check_dir, expected_dir = Path(sys.argv[1]), Path(sys.argv[2])
mode = os.environ.get("CHECK_MODE", "")
if mode not in ("signed", "unsigned"):
    unusable(f"CHECK_MODE must be signed or unsigned, got '{mode}'.")
if not check_dir.is_dir():
    unusable(f"the check directory {check_dir} does not exist; the Gradle publication did not run.")
if not expected_dir.is_dir():
    unusable(f"the publication guard's directory {expected_dir} does not exist, so there is nothing "
             f"to compare against.")
version_file = Path(str(check_dir) + ".gradle-version")
if not version_file.is_file():
    unusable(f"{version_file.name} is missing; the check's init script did not run.")
raw_version = version_file.read_text().strip()
m = re.match(r"^(\d+)\.(\d+)", raw_version)
if not m:
    unusable(f"cannot read a Gradle version from '{raw_version}'.")
asc_checksums_expected = (int(m.group(1)), int(m.group(2))) < (9, 7)

present = files_under(check_dir)
artifacts = {p for p in present if is_artifact(p)}
expected = {p for p in files_under(expected_dir) if is_artifact(p)}

# Nothing bound for Central: the guard warns and passes on the same case, and a new refusal here
# would turn consumers' required dry-run checks red on nothing but an octopus-base bump. Anything
# that DID land in the check directory is still judged below.
if not expected and not artifacts:
    print("::warning title=No Central checksum files to check::The guard saw no publication bound "
          "for Maven Central, so there is nothing to check.", flush=True)
    sys.exit(0)

problems = []
for p in sorted(expected - artifacts):
    problems.append(f"{p} is missing: Central would not receive it")
for p in sorted(artifacts - expected):
    problems.append(f"{p} was not in the guard's view of the build: a publication routed away from "
                    f"Central, or a build that differs between the two invocations")
for p in sorted(present):
    if p.endswith(FORBIDDEN):
        problems.append(f"{p} would be uploaded: the checksum flag did not take effect")
for f in sorted(artifacts):
    for ext in (".md5", ".sha1"):
        if f + ext not in present:
            problems.append(f"{f}{ext} is missing: Central requires it")
    if mode == "signed":
        if f + ".asc" not in present:
            problems.append(f"{f}.asc is missing: Central requires a signature")
        elif not asc_checksums_expected:
            for ext in (".md5", ".sha1"):
                if f + ".asc" + ext in present:
                    problems.append(f"{f}.asc{ext} was written on Gradle {raw_version}, which "
                                    f"writes no checksums of signatures")

# The full list, in the log: the evidence of what the upload will send (octopus-base#238).
manifest = sorted(present)
print("::group::Files this release would upload to Maven Central")
for p in manifest:
    print(f"  {p}")
print("::endgroup::")

per = {len([p for p in present if p == f or p.startswith(f + ".")]) for f in artifacts}
shape = str(per.pop()) if len(per) == 1 else "mixed"
print(f"{len(manifest)} files for {len(artifacts)} artifact files; "
      f"files per artifact file: {shape} (Gradle {raw_version}, {mode})")

if problems:
    print("RELEASE_PUBLISH_CLASS=deterministic")
    print("RELEASE_PUBLISH_RETRYABLE=false")
    for p in problems:
        print(f"::error title=Central checksum check::{p}")
    print(f"{len(problems)} problem(s). Nothing was staged, so re-running after the fix is safe.")
    sys.exit(1)
print("OK: All checks passed.")
