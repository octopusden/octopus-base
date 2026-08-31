#!/usr/bin/env bash
#
# Runs .github/scripts/list-publications.init.gradle against a REAL Gradle build and checks
# what it lists. The bash side of the preflight is covered by stubs; this is the half that
# cannot be stubbed, and it is the half that decides whether the check does anything at all —
# a silently empty coordinate file disables the preflight without failing anything.
#
# The fixture is this repository's own gradle-quality-plugin: it applies java-gradle-plugin,
# which creates its plugin MARKER publication inside its own `afterEvaluate`. That is the
# case a hook running any earlier would miss, and the marker is a real Central coordinate.
#
# Usage: bash .github/scripts/test/list-publications-fixture.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
INIT="$root/.github/scripts/list-publications.init.gradle"
FIXTURE="$root/gradle-quality-plugin"
[ -f "$INIT" ] || { echo "list-publications.init.gradle not found"; exit 1; }
[ -x "$FIXTURE/gradlew" ] || { echo "fixture build not found at $FIXTURE"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"

# list <wanted-version> <version-the-build-is-at> [extra gradle args...]
#   -> coordinates in $tmp/coords, Gradle output in $tmp/log
#
# The two versions are separate arguments because the interesting case is when they DIFFER:
# a subproject whose build script pins its own version ignores the release's -Pversion, and
# its publication must not be checked against Central under the release version. Passing one
# version for both would make that case untestable — the publications would always match.
list() {
  local want="$1" built="$2"; shift 2
  : > "$tmp/coords"
  ( cd "$FIXTURE" && OCTOPUS_COORDS_FILE="$tmp/coords" OCTOPUS_RELEASE_VERSION="$want" \
      ./gradlew help -q --init-script "$INIT" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false \
      -Pnexus=true -PbuildVersion="$built" -Pversion="$built" "$@" ) > "$tmp/log" 2>&1
}

# check <name> <what-it-means-if-it-failed>
# Reads the exit status of the command that ran immediately before the call, so a check
# reads as `<condition>; check "name" "meaning"` with no status threading at the call site.
check() {
  local rc=$?
  if [ "$rc" = "0" ]; then echo "PASS  $1"; pass=$((pass+1)); else
    echo "FAIL  $1 ($2)"; fail=$((fail+1))
    echo "--- coords:"; sed 's/^/    /' "$tmp/coords"
    echo "--- log tail:"; tail -n 25 "$tmp/log" | sed 's/^/    /'
  fi
}

echo "-- publications at the release version ------------------------------------"
list 9.9.9-fixture 9.9.9-fixture
grep -qxF 'org.octopusden.octopus:octopus-quality-plugin' "$tmp/coords"; check \
  "lists the library publication" "main publication missing"
grep -qxF 'org.octopusden.octopus-quality:org.octopusden.octopus-quality.gradle.plugin' "$tmp/coords"; check \
  "lists the plugin marker publication" "marker publication missing — a hook that runs before java-gradle-plugin's afterEvaluate would do this"
! grep -q ':.*:' "$tmp/coords"; check \
  "writes group:artifact, with no version attached" "a line carries a version, which central-preflight.sh would refuse"
[ "$(sort -u "$tmp/coords" | wc -l)" = "$(wc -l < "$tmp/coords")" ]; check \
  "writes no duplicates" "the coordinate set is not deduplicated"

echo "-- a multi-project build --------------------------------------------------"
# Generated rather than reusing the plugin build, which is single-project: with only a root
# project, `allprojects` and `[rootProject]` are the same thing, so the traversal the release
# workflow depends on is untested. On a real consumer that difference means every subproject's
# publications go unchecked — silently, because the check fails open.
multi="$tmp/multi"
mkdir -p "$multi/sub"
cat > "$multi/settings.gradle" <<'G'
rootProject.name = 'fixture-root'
include 'sub'
G
cat > "$multi/build.gradle" <<'G'
allprojects {
    apply plugin: 'maven-publish'
    apply plugin: 'ivy-publish'
    group = "org.fixture.${project.name}"
    version = project.property('fixtureVersion')
    publishing {
        publications {
            register(project.name, MavenPublication) { }
            // Same coordinates as the one above. The listing must collapse them, or the
            // "writes no duplicates" assertion is describing an input that never occurs.
            register("${project.name}Twin", MavenPublication) {
                groupId = "org.fixture.${project.name}"
                artifactId = project.name
            }
            // Pinned to another version, so it is NOT part of what this release uploads.
            // Filtering on the PROJECT's version instead of the PUBLICATION's would list it.
            register("${project.name}Pinned", MavenPublication) {
                artifactId = "${project.name}-pinned"
                version = '0.0.1-pinned'
            }
            // Not a Maven publication at all: it has no groupId, so a listing that does not
            // check the type reaches for one and dies, taking the whole check with it.
            register("${project.name}Ivy", IvyPublication) { }
        }
    }
}
G
: > "$tmp/coords"
( cd "$FIXTURE" && OCTOPUS_COORDS_FILE="$tmp/coords" OCTOPUS_RELEASE_VERSION=7.7.7 \
    ./gradlew --project-dir "$multi" help -q --init-script "$INIT" \
    -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false \
    -PfixtureVersion=7.7.7 ) > "$tmp/log" 2>&1

grep -qxF 'org.fixture.fixture-root:fixture-root' "$tmp/coords"; check \
  "lists the root project's publication" "root publication missing"
grep -qxF 'org.fixture.sub:sub' "$tmp/coords"; check \
  "lists a SUBPROJECT's publication" "subproject publication missing — a hook that walks only the root project would do this, and every subproject of every consumer would go unchecked"
! grep -q 'pinned' "$tmp/coords"; check \
  "excludes a publication pinned to another version" "a publication carrying its own version was listed under the release version — this is the direction that can produce a false 'all published' and stop a valid release"
[ "$(wc -l < "$tmp/coords" | tr -d ' ')" = "2" ]; check \
  "lists exactly the two coordinates this release would upload" "the line count is not 2, so a duplicate, the pinned publication or the Ivy publication leaked in"

echo "-- publications at another version ----------------------------------------"
# The build is at 9.9.9-fixture; the release claims to be releasing 1.2.3. Nothing matches.
list 1.2.3 9.9.9-fixture
[ ! -s "$tmp/coords" ]; check \
  "lists nothing when no publication is at that version" "coordinates were written for a version this build is not at"
grep -q "not the version being released" "$tmp/log"; check \
  "says which publications it dropped and why" "the skipped publications were not reported"

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
