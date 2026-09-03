#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/inspect-publication-set.py.
#
# The input is a local Maven repository, so the fixtures are directory trees written here — no
# Gradle needed. That is what makes the refusals testable at all: they depend on the layout
# (`<group path>/<artifact>/<version>/<file>`) and on what is inside the archives.
#
# This guard had no tests before the version refusal was added to it, which is the wrong way
# round: its failure mode is to wave something through to an immutable public repository.
#
# Usage: bash .github/scripts/test/publication-set-scenarios.sh   (from the repo root)

# shellcheck disable=SC2016,SC2034
# The SETUP values are single-quoted on purpose: they are fixture code, eval'd inside run()
# once $repo exists. $G is referenced from inside them, which shellcheck cannot see.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../inspect-publication-set.py"
[ -f "$SCRIPT" ] || { echo "inspect-publication-set.py not found"; exit 1; }

pass=0; fail=0

# pom <repo> <group-path> <artifact> <version>
# Every Maven publication writes one, archive or not, so the fixtures do too — the version
# check enumerates publications from their POMs, which is the only way a POM-only publication
# (a BOM) is seen at all.
pom() {
  local dir="$1/$2/$3/$4"; mkdir -p "$dir"
  printf '<project><artifactId>%s</artifactId><version>%s</version></project>\n' "$3" "$4" > "$dir/$3-$4.pom"
}

# jar <repo> <group-path> <artifact> <version> <filename> [entry-inside] — writes the POM too
jar() {
  pom "$1" "$2" "$3" "$4"
  local dir="$1/$2/$3/$4"; mkdir -p "$dir"
  local target="$dir/$5"
  if [ -n "${6:-}" ]; then
    local stage; stage="$(mktemp -d)"; mkdir -p "$stage/$(dirname "$6")"
    echo x > "$stage/$6"
    ( cd "$stage" && zip -q -r "$target" . )
    rm -rf "$stage"
  else
    # A minimal real zip, so the Spring Boot probe reads a valid archive rather than skipping it.
    local stage; stage="$(mktemp -d)"; echo x > "$stage/a.txt"
    ( cd "$stage" && zip -q -r "$target" . )
    rm -rf "$stage"
  fi
}

# pad <path> <mb> — grow a file past the size limit
pad() { local f="$1"; local mb="$2"; dd if=/dev/zero bs=1048576 count="$mb" >> "$f" 2>/dev/null; }

# sized <path> <mb> — set an EXACT size, for the boundary case. Appending cannot do it: the zip
# content would push the file just over, which is how this fixture first read as "exceeds".
sized() { truncate -s $(( $2 * 1048576 )) "$1"; }

# shaded <jar> — rewrite a jar as a shadow jar whose classifier was stripped: an executable
# manifest plus classes from several third-party package roots, and no -all in the name.
shaded() {
  local target="$1" stage; stage="$(mktemp -d)"
  mkdir -p "$stage/META-INF"
  printf 'Manifest-Version: 1.0\nMain-Class: org.fixture.Main\n' > "$stage/META-INF/MANIFEST.MF"
  for r in kotlin org com net io; do mkdir -p "$stage/$r"; echo x > "$stage/$r/C.class"; done
  rm -f "$target"
  ( cd "$stage" && zip -q -r "$target" . )
  rm -rf "$stage"
}

# run <name> <expected-rc> <must-match> [<must-not-match>]  — fixture built by $SETUP
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  local repo; repo="$(mktemp -d)"
  eval "${SETUP}"
  local out; out="$(mktemp)"
  # Omitted rather than emptied when NO_MAX is set: the script's fallback fires on unset OR
  # empty, but only omitting it proves the fallback rather than the empty-string branch.
  local -a envs=(-u MAX_ARTIFACT_MB "BUILD_VERSION=${VERSION-2.0.105}" "FAT_JAR_ALLOWLIST=${ALLOWLIST:-}" "OVERSIZE_ALLOWLIST=${OVERSIZE:-}" "DRY_RUN=${DRY:-false}")
  [ "${NO_MAX:-}" = "1" ] || envs+=("MAX_ARTIFACT_MB=${MAX_MB:-8}")
  env "${envs[@]}" python3 "$SCRIPT" "$repo" >"$out" 2>&1
  local rc=$? ok=true
  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
  fi
  rm -rf "$repo" "$out"
}

G=org/octopusden/octopus

# An empty publication set is now annotated rather than reported as fit, because "the inspector
# looked and approved" and "the inspector saw nothing" were indistinguishable — including when
# the fixture builder itself breaks, since this suite runs without `set -e`.
echo "-- an empty publication set is not success --------------------------------"
SETUP='true' \
  run "annotates an empty set instead of calling it fit" 0 "Nothing to inspect"

echo "-- a release publishes exactly one version --------------------------------"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar' \
  run "accepts a publication at the release version" 0 "client-2\.0\.105\.jar +[0-9]"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' \
  run "refuses Gradle's unspecified version" 1 "carries version 'unspecified'"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' \
  run "surfaces the refusal as an Actions error annotation" 1 "^::error::"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' DRY=true \
  run "surfaces the dry-run report as a warning annotation" 0 "^::warning::"
SETUP='jar "$repo" "$G" client 0.0.0 client-0.0.0.jar' \
  run "refuses any other version" 1 "carries version '0.0.0'"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar
jar "$repo" "$G" legacy unspecified legacy-unspecified.jar' \
  run "refuses when only ONE of several publications is adrift" 1 "legacy carries version"
# Every offender must be named, not just the first: an operator fixing one and re-running would
# otherwise discover the next one a build at a time.
SETUP='jar "$repo" "$G" alpha unspecified alpha-unspecified.jar
jar "$repo" "$G" beta 0.0.0 beta-0.0.0.jar' \
  run "names every adrift publication, not just the first" 1 "alpha carries version"
SETUP='jar "$repo" "$G" alpha unspecified alpha-unspecified.jar
jar "$repo" "$G" beta 0.0.0 beta-0.0.0.jar' \
  run "names the second adrift publication too" 1 "beta carries version"
# The allowlist says an artifact may be a fat jar. It says nothing about the version, and
# `unspecified` is a defect rather than a choice — so it must not exempt this refusal.
SETUP='jar "$repo" "$G" automation unspecified automation-unspecified-all.jar' ALLOWLIST=automation \
  run "the fat-jar allowlist does not exempt a foreign version" 1 "carries version 'unspecified'"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' VERSION='' \
  run "checks nothing when no release version is known" 0 "Enumerated 1 publication\(s\) from their POMs and inspected 1 archive" "carries version"
# A padded value must compare equal to the artifact's version, or every publication reads as
# adrift and no release could ever pass.
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar' VERSION='  2.0.105
' \
  run "trims the release version before comparing" 0 "Enumerated 1 publication\(s\) from their POMs and inspected 1 archive" "carries version"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' \
  run "says which release version it expected" 1 "This release is 2.0.105"
SETUP='jar "$repo" "$G" client 0.105 client-0.105.jar' \
  run "refuses a version that is a substring of the release version" 1 "carries version '0.105'"
SETUP='pom "$repo" "$G" bom unspecified' \
  run "refuses a POM-only publication at another version" 1 "carries version 'unspecified'"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar
pom "$repo" org/other client unspecified' \
  run "names the group, so same-named artifacts are distinguishable" 1 "org.other:client"

echo "-- artifacts unfit for Central (pre-existing rules) -----------------------"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' \
  run "refuses a shadow/uber artifact" 1 "shadow/uber"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' ALLOWLIST=automation \
  run "accepts an allowlisted shadow artifact" 0 "automation-2\.0\.105-all\.jar +[0-9]" "unfit for Maven Central"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' ALLOWLIST='other, automation' \
  run "tolerates spaces in the allowlist, as YAML writes it" 0 "allowlist \(deprecated\): automation, other" "unfit for Maven Central"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.zip' \
  run "refuses a shadow distribution ZIP, not only a jar" 1 "shadow/uber"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.tar.gz' \
  run "refuses a shadow distribution tarball" 1 "shadow/uber"
SETUP='jar "$repo" "$G" app 2.0.105 app-2.0.105.jar BOOT-INF/classes/x.class' \
  run "refuses a Spring Boot executable jar" 1 "BOOT-INF"
# The probe must match the DIRECTORY, not the prefix: an entry merely starting with those
# letters is not a Spring Boot layout.
SETUP='jar "$repo" "$G" lib 2.0.105 lib-2.0.105.jar BOOT-INFRASTRUCTURE/x.txt' \
  run "accepts a jar whose entry merely starts with those letters" 0 "lib-2\.0\.105\.jar +[0-9]" "BOOT-INF"
SETUP='jar "$repo" "$G" big 2.0.105 big-2.0.105.jar; pad "$repo/$G/big/2.0.105/big-2.0.105.jar" 9' \
  run "refuses an oversized artifact" 1 "exceeds 8 MB"
SETUP='jar "$repo" "$G" big 2.0.105 big-2.0.105.jar; pad "$repo/$G/big/2.0.105/big-2.0.105.jar" 9' MAX_MB=16 \
  run "accepts it under a raised limit" 0 "big-2\.0\.105\.jar +[0-9]" "exceeds"
# The limit is a ceiling, not a floor: at exactly the limit the artifact passes. Without this
# the comparison could be flipped to >= and nothing would notice.
SETUP='jar "$repo" "$G" edge 2.0.105 edge-2.0.105.jar; sized "$repo/$G/edge/2.0.105/edge-2.0.105.jar" 4' MAX_MB=4 \
  run "accepts an artifact exactly at the limit" 0 "edge-2\.0\.105\.jar +[0-9]" "exceeds"
# MAX_ARTIFACT_MB unset, so the script's own 8 MB fallback decides — the workflow passes the
# input explicitly, so this is the only place that default is ever exercised.
SETUP='jar "$repo" "$G" big 2.0.105 big-2.0.105.jar; pad "$repo/$G/big/2.0.105/big-2.0.105.jar" 9' NO_MAX=1 \
  run "falls back to an 8 MB limit when none is given" 1 "exceeds 8 MB"

echo "-- the version refusal comes first ---------------------------------------"
# Both defects at once: the version is the one to report, since it means the build is wrong
# rather than the artifact being unsuitable.
SETUP='jar "$repo" "$G" automation unspecified automation-unspecified-all.jar' \
  run "reports the version, not the shadow classifier" 1 "carries version 'unspecified'" "shadow/uber"

echo "-- a dry run has no upload to save, so it must not fail -------------------"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' DRY=true \
  run "warns instead of refusing under dry-run" 0 "a real release would stop here" "::error"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' DRY=true \
  run "still names the offending coordinate under dry-run" 0 "carries version 'unspecified'"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' DRY=true \
  run "keeps refusing a fat jar under dry-run, as it always has" 1 "shadow/uber"

echo "-- a publication with no archive is checked, not reported as unchecked ----"
# The archive glob is not the enumeration. A BOM or a java-gradle-plugin marker has a POM and
# no jar; reporting "nothing was checked" there would be false, and would hide the case the
# POM enumeration exists for.
SETUP='pom "$repo" "$G" platform-bom 2.0.105' \
  run "a POM-only publication does not report an empty set" 0 "Enumerated 1 publication" "Nothing to inspect"
SETUP='pom "$repo" "$G" platform-bom 2.0.105' \
  run "a POM-only publication is listed as having no archive" 0 "POM-only publication"
SETUP='pom "$repo" "$G" marker unspecified' \
  run "a POM-only publication at the wrong version is still refused" 1 "carries version 'unspecified'"
SETUP=':' \
  run "a genuinely empty repository still warns" 0 "Nothing to inspect"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar; pom "$repo" "$G" client-bom 2.0.105' \
  run "an archive and a POM-only publication are counted separately" 0 "Enumerated 2 publication\(s\) from their POMs and inspected 1 archive"
# The listing used to match archives by artifactId alone, so the same artifactId at two
# versions — one with a jar, one without — hid the POM-only line for the version that had none.
SETUP='pom "$repo" "$G" twin 1.0; jar "$repo" "$G" twin 2.0 twin-2.0.jar' VERSION= \
  run "a POM-only version is listed even when the same artifactId has an archive elsewhere" 0 "twin.*POM-only publication"

# A stray POM above the g/a/v layout used to raise ValueError out of relative_to, replacing
# the step's message with a traceback. It fails closed either way; it must fail legibly.
SETUP='mkdir -p "$repo"; printf "<project/>\n" > "$repo/stray.pom"' \
  run "a POM outside the layout is skipped, not a traceback" 0 "Unrecognised file in the publication set" "Traceback"
SETUP='mkdir -p "$repo"; printf "<project/>\n" > "$repo/stray.pom"; pom "$repo" "$G" client 2.0.105' \
  run "and the real publications beside it are still checked" 0 "Enumerated 1 publication" "Traceback"

echo "-- the closing verdict may not contradict the refusal above ---------------"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' DRY=true \
  run "a dry run that refused does not end with \"fit\"" 0 "Publication set is NOT fit" "Publication set is fit for Maven Central"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar' DRY=true \
  run "a clean dry run still ends with \"fit\"" 0 "Publication set is fit for Maven Central" "NOT fit"

echo "-- the environment contract is documented -------------------------------"
if grep -qE '^Env: .*DRY_RUN' "$SCRIPT"; then
  echo "PASS  DRY_RUN is named in the script's own env contract"; pass=$((pass+1))
else
  echo "FAIL  DRY_RUN is named in the script's own env contract"; fail=$((fail+1))
fi

# --- the two exceptions are separate ------------------------------------------------------
# The guard makes two unrelated complaints, and one list used to waive both. Keyed by
# artifactId — which a module's thin and fat jars share — an exception admitting the fat jar
# also stopped the thin one being checked. The size list must therefore be UNABLE to admit an
# executable artifact, which is the assertion the split exists for.
SETUP='jar "$repo" "$G" biglib 2.0.105 biglib-2.0.105.jar; pad "$repo/$G/biglib/2.0.105/biglib-2.0.105.jar" 9' \
  OVERSIZE=biglib run "size list admits a legitimately large library" 0 "biglib" "unfit for Maven Central"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' OVERSIZE=automation \
  run "size list does NOT admit an executable artifact" 1 "shadow/uber"
SETUP='jar "$repo" "$G" app 2.0.105 app-2.0.105.jar BOOT-INF/classes/x.class' OVERSIZE=app \
  run "size list does NOT admit a Spring Boot jar" 1 "BOOT-INF"

# --- the deprecated list still works, and says so -----------------------------------------
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' ALLOWLIST=automation \
  run "warns that the fat-jar list is deprecated" 0 "is deprecated" "unfit for Maven Central"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' ALLOWLIST=automation \
  run "points at the replacement" 0 "github-packages-publications"

# --- a shadow jar with its classifier stripped --------------------------------------------
# No name rule can see this shape, so it is reported and NOT refused: Main-Class alone is
# ordinary — a thin CLI jar sets it — and a package-root count is a heuristic, so a hard rule
# could block a valid release with no override.
SETUP='jar "$repo" "$G" stripped 2.0.105 stripped-2.0.105.jar; shaded "$repo/$G/stripped/2.0.105/stripped-2.0.105.jar"' \
  run "warns about a stripped-classifier shadow jar" 0 "looks like a shadow jar" "unfit for Maven Central"
SETUP='jar "$repo" "$G" thin 2.0.105 thin-2.0.105.jar META-INF/MANIFEST.MF' \
  run "does not warn about an ordinary jar" 0 "" "looks like a shadow jar"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
