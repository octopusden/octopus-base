#!/usr/bin/env bash
#
# Runs the Central checksum check against a REAL Gradle build, on one version below 9.7 and one at
# or above it.
#
# central-checksum-scenarios.sh tests the rule against prepared directories. Those cannot show what
# Gradle actually writes, nor that the check's repository is registered early enough for the routing
# to see it. This does both, with the scripts the workflow runs: the routing and no-signing scripts
# are read out of common-java-gradle-release.yml, as publication-routing-fixture.sh does, and the
# check's init script and checker are the files the workflow fetches.
#
# The build has the shape that makes the ordering matter: a Central publication that a consumer would
# sign, and one routed to GitHub Packages. If the routing never saw the check's publish tasks, the
# routed one would land in the check directory as an extra file.
#
# Usage: bash .github/scripts/test/central-checksum-fixture.sh   (from the repo root)
# Needs Java, and network access to download the two Gradle distributions.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORKFLOW="$root/.github/workflows/common-java-gradle-release.yml"
INIT="$root/.github/scripts/central-checksum-check.init.gradle"
CHECKER="$root/.github/scripts/check-central-checksums.py"
WRAPPER_DIR="$root/gradle-quality-plugin"
FLAG='-Dorg.gradle.internal.publish.checksums.insecure=true'
# Below 9.7: the most common version among consumers. At or above: the current release.
VERSIONS="${CHECKSUM_FIXTURE_GRADLE_VERSIONS:-8.14.3 9.8.0}"
for f in "$WORKFLOW" "$INIT" "$CHECKER" "$WRAPPER_DIR/gradlew"; do
  [ -f "$f" ] || { echo "not found: $f"; exit 1; }
done

pass=0; fail=0
tmp="$(mktemp -d)"
cleanup() {
  [ -x "$tmp/fixture/gradlew" ] && (cd "$tmp/fixture" && ./gradlew --stop >/dev/null 2>&1)
  rm -rf "$tmp"
}
trap cleanup EXIT

# extract <step name> <heredoc marker regex> <file> — a heredoc body out of a workflow step.
extract() {
  awk -v step="- name: $1" -v open="$2" '
    index($0, step) { instep = 1; next }
    instep && !inbody && $0 ~ open { inbody = 1; next }
    inbody && $1 == "GRADLE" { exit }
    inbody { print }
  ' "$WORKFLOW" > "$3"
}
ROUTING="$tmp/publication-routing.init.gradle"
NOSIGN="$tmp/no-signing.init.gradle"
extract 'Prepare publication routing init script' '<<.GRADLE.' "$ROUTING"
extract 'Guard against publishing fat jars to Maven Central' 'no-signing.init.gradle.*<<.GRADLE.' "$NOSIGN"
grep -qF 'publishSelectedPublicationsToGitHubPackages' "$ROUTING" \
  || { echo "could not extract the routing init script from $WORKFLOW"; exit 1; }
grep -qF 'required = false' "$NOSIGN" \
  || { echo "could not extract the guard's no-signing init script from $WORKFLOW"; exit 1; }

fixture="$tmp/fixture"
mkdir -p "$fixture/gradle/wrapper" "$fixture/src/main/java/org/fixture"
cp "$WRAPPER_DIR/gradlew" "$fixture/gradlew"
cp "$WRAPPER_DIR/gradle/wrapper/gradle-wrapper.jar" "$fixture/gradle/wrapper/"
printf 'package org.fixture;\n/** Fixture. */\npublic class Lib {}\n' > "$fixture/src/main/java/org/fixture/Lib.java"
echo "rootProject.name = 'lib'" > "$fixture/settings.gradle"
# No explicit `required`: a release version then requires signing, as in a consumer build, and only
# the no-signing script turns that off. There is no key here, as there is none in the check step.
cat > "$fixture/build.gradle" <<'G'
apply plugin: 'java'
apply plugin: 'maven-publish'
apply plugin: 'signing'
group = 'org.fixture'
version = '1.0.0'
java { withSourcesJar(); withJavadocJar() }
publishing {
    publications {
        register('libJava', MavenPublication) { from components.java }
        register('fatJava', MavenPublication) {
            artifactId = 'lib-fat'
            artifact(tasks.jar) { classifier = 'all' }
        }
    }
    repositories { maven { name = 'GitHubPackages'; url = uri("${rootDir}/out-github") } }
}
signing { sign(publishing.publications['libJava']) }
G

GUARD="$tmp/guard"
CHECK="$tmp/check"
LIB="$CHECK/org/fixture/lib/1.0.0"

# gradle <routed publications> <log> <args...> — the fixture's wrapper, as the workflow runs it.
gradle() {
  local routed="$1" log="$2"; shift 2
  ( cd "$fixture" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS="$routed" ./gradlew "$@" -Pnexus=true \
      --init-script "$ROUTING" --init-script "$NOSIGN" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false -s ) > "$log" 2>&1
}

# run_both <routed publications> [flag] — the guard's publication, then the check's.
run_both() {
  rm -rf "$GUARD" "$CHECK"
  gradle "$1" "$tmp/guard.log" publishToMavenLocal -Dmaven.repo.local="$GUARD" \
    && OCTOPUS_CHECKSUM_CHECK_REPO="$CHECK" gradle "$1" "$tmp/check.log" \
         publishAllPublicationsToCentralChecksumCheckRepository ${2:+"$2"} --init-script "$INIT"
}

# check <name> <what-it-means-if-it-failed> [log] — reads the status of the preceding command.
check() {
  local rc=$?
  if [ "$rc" = 0 ]; then echo "PASS  $1"; pass=$((pass+1)); else
    echo "FAIL  $1 ($2)"; fail=$((fail+1))
    echo "--- check directory:"; (cd "$CHECK" 2>/dev/null && find . -type f | sort | sed 's/^/    /')
    [ -n "${3:-}" ] && { echo "--- log tail:"; tail -n 25 "$3" | sed 's/^/    /'; }
  fi
}

checker() { python3 "$CHECKER" "$CHECK" "$GUARD" > "$tmp/checker.log" 2>&1; }

for version in $VERSIONS; do
  echo "-- Gradle $version -----------------------------------------------------"
  printf 'distributionUrl=https\\://services.gradle.org/distributions/gradle-%s-bin.zip\n' "$version" \
    > "$fixture/gradle/wrapper/gradle-wrapper.properties"

  run_both ":fatJava" "$FLAG"
  check "the guard's and the check's publications run, without a key" "Gradle failed" "$tmp/check.log"
  checker; check "the checker accepts what Gradle writes with the flag" "see the checker log" "$tmp/checker.log"
  [ -f "$LIB/lib-1.0.0.jar.md5" ] && [ -f "$LIB/lib-1.0.0.jar.sha1" ] && [ ! -e "$LIB/lib-1.0.0.jar.sha256" ]; check \
    "the flag keeps md5 and sha1 and drops sha256" "a -D on the command line did not reach the publisher"
  [ -d "$LIB" ] && ! find "$CHECK" -name 'lib-fat*' | grep -q .; check \
    "the routed publication never reaches the check directory" \
    "the check's repository was registered too late for the routing to disable its publish tasks"

  # The regression the check exists for: the flag no longer taking effect.
  run_both ":fatJava" ""
  check "the publications run without the flag" "Gradle failed for another reason" "$tmp/check.log"
  checker; [ $? = 1 ] && grep -q 'lib-1.0.0.jar.sha256 would be uploaded' "$tmp/checker.log"; check \
    "without the flag, the checker refuses the upload" "a real sha256 went unnoticed"

  # Everything routed away: Gradle skips every publish task and creates neither directory.
  run_both ":fatJava, :libJava" "$FLAG"
  check "the publications run with everything routed away" "Gradle failed" "$tmp/check.log"
  checker; check "and the checker passes, as the guard does" "see the checker log" "$tmp/checker.log"

  (cd "$fixture" && ./gradlew --stop >/dev/null 2>&1)
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
