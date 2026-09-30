#!/usr/bin/env bash
#
# Runs the Central checksum check against a REAL Gradle build, on one version below 9.7 and one
# at or above it (octopus-base#238).
#
# central-checksum-scenarios.sh tests the rules against prepared directories. Those cannot show
# what Gradle actually writes, nor that the check's repository is registered early enough for the
# routing to see it. This does both, with the same init scripts the workflow runs: the routing
# script is read out of common-java-gradle-release.yml, as publication-routing-fixture.sh does,
# and the check's init script and checker are the files the workflow fetches.
#
# The build has the shape that makes the ordering matter: a signed Central publication, and an
# unsigned one routed to GitHub Packages. If the routing never saw the check's publish tasks, the
# routed one would land in the check directory and fail for want of a signature.
#
# Signing uses a throwaway key generated here, never the release key.
#
# Usage: bash .github/scripts/test/central-checksum-fixture.sh   (from the repo root)
# Needs Java, gpg, and network access to download the two Gradle distributions.

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
command -v gpg >/dev/null || { echo "gpg is required to generate the throwaway signing key"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"
cleanup() {
  [ -x "$tmp/fixture/gradlew" ] && (cd "$tmp/fixture" && ./gradlew --stop >/dev/null 2>&1)
  GNUPGHOME="$tmp/gnupg" gpgconf --kill gpg-agent >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

# The routing script, extracted exactly as publication-routing-fixture.sh extracts it.
ROUTING="$tmp/publication-routing.init.gradle"
awk '
  /- name: Prepare publication routing init script/ { instep = 1; next }
  instep && !inbody && /<<.GRADLE./ { inbody = 1; next }
  inbody && $1 == "GRADLE" { exit }
  inbody { print }
' "$WORKFLOW" > "$ROUTING"
grep -qF 'publishSelectedPublicationsToGitHubPackages' "$ROUTING" \
  || { echo "could not extract the routing init script from $WORKFLOW"; exit 1; }

# The guard's signing switch, which the check's dry run reuses, extracted from the guard step.
NOSIGN="$tmp/no-signing.init.gradle"
awk '
  /- name: Guard against publishing fat jars to Maven Central/ { instep = 1; next }
  instep && !inbody && /no-signing.init.gradle.*<<.GRADLE./ { inbody = 1; next }
  inbody && $1 == "GRADLE" { exit }
  inbody { print }
' "$WORKFLOW" > "$NOSIGN"
grep -qF "required = false" "$NOSIGN" \
  || { echo "could not extract the guard's no-signing init script from $WORKFLOW"; exit 1; }

export GNUPGHOME="$tmp/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase fixture \
  --quick-gen-key 'Checksum Fixture <fixture@example.invalid>' rsa2048 sign never >/dev/null 2>&1 \
  || { echo "gpg could not generate the throwaway key"; exit 1; }
KEY="$(gpg --batch --pinentry-mode loopback --passphrase fixture --armor --export-secret-keys 2>/dev/null)"
[ -n "$KEY" ] || { echo "gpg exported no key"; exit 1; }

fixture="$tmp/fixture"
mkdir -p "$fixture/gradle/wrapper"
cp "$WRAPPER_DIR/gradlew" "$fixture/gradlew"
cp "$WRAPPER_DIR/gradle/wrapper/gradle-wrapper.jar" "$fixture/gradle/wrapper/"
cat > "$fixture/settings.gradle" <<'G'
rootProject.name = 'lib'
G
# No explicit `required`: a release version then requires signing, as in a consumer build, and
# only the dry-run switch turns that off.
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
signing {
    def key = findProperty('signingKey')
    if (key) { useInMemoryPgpKeys(key, findProperty('signingPassword')) }
    sign(publishing.publications['libJava'])
}
G
mkdir -p "$fixture/src/main/java/org/fixture"
printf 'package org.fixture;\n/** Fixture. */\npublic class Lib {}\n' > "$fixture/src/main/java/org/fixture/Lib.java"

GUARD="$tmp/guard"
CHECK="$tmp/check"
G_DIR="org/fixture/lib/1.0.0"

# gradle <log> <args...> — the fixture's wrapper, routing :fatJava away from Central.
gradle() {
  local log="$1"; shift
  ( cd "$fixture" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS=":fatJava" ./gradlew "$@" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false -s ) > "$log" 2>&1
}

# checker <mode> -> $tmp/checker.log, returns its exit code
checker() {
  CHECK_MODE="$1" python3 "$CHECKER" "$CHECK" "$GUARD" > "$tmp/checker.log" 2>&1
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

# publish_check <signed|unsigned> [flag] — the check step's Gradle invocation.
publish_check() {
  local mode="$1" flag="${2:-}"
  rm -rf "$CHECK" "$CHECK.gradle-version"
  if [ "$mode" = signed ]; then
    ORG_GRADLE_PROJECT_signingKey="$KEY" ORG_GRADLE_PROJECT_signingPassword=fixture \
      OCTOPUS_CHECKSUM_CHECK_REPO="$CHECK" \
      gradle "$tmp/check.log" publishAllPublicationsToCentralChecksumCheckRepository -Pnexus=true $flag \
        --init-script "$INIT" --init-script "$ROUTING"
  else
    OCTOPUS_CHECKSUM_CHECK_REPO="$CHECK" \
      gradle "$tmp/check.log" publishAllPublicationsToCentralChecksumCheckRepository -Pnexus=true $flag \
        --init-script "$INIT" --init-script "$ROUTING" --init-script "$NOSIGN"
  fi
}

for version in $VERSIONS; do
  echo "-- Gradle $version -----------------------------------------------------"
  printf 'distributionUrl=https\\://services.gradle.org/distributions/gradle-%s-bin.zip\n' "$version" \
    > "$fixture/gradle/wrapper/gradle-wrapper.properties"
  below_97=false
  case "$version" in 8.*|9.[0-6]|9.[0-6].*) below_97=true ;; esac

  # The guard's routed view, which the checker takes the expected set from.
  rm -rf "$GUARD"
  gradle "$tmp/guard.log" publishToMavenLocal -Pnexus=true -Dmaven.repo.local="$GUARD" \
    --init-script "$NOSIGN" --init-script "$ROUTING"
  check "the guard's publication runs" "publishToMavenLocal failed" "$tmp/guard.log"

  publish_check signed "$FLAG"
  check "the signed check publication runs" "the Gradle half of the real-upload check failed" "$tmp/check.log"
  grep -q "^$version\$" "$CHECK.gradle-version"; check \
    "the init script records the running Gradle version" "the checker would apply the wrong signature rule"
  checker signed; check "the checker accepts a correct signed upload" "see $tmp/checker.log" "$tmp/checker.log"
  [ -d "$CHECK/$G_DIR" ] && ! find "$CHECK" -name 'lib-fat*' | grep -q .; check \
    "the routed publication never reaches the check directory" \
    "the check's repository was registered too late for the routing to disable its publish tasks"
  [ -f "$CHECK/$G_DIR/lib-1.0.0.jar.asc" ] && [ -f "$CHECK/$G_DIR/lib-1.0.0.jar.md5" ] \
    && [ -f "$CHECK/$G_DIR/lib-1.0.0.jar.sha1" ]; check \
    "the Central publication is signed and has md5 and sha1" "the build did not sign, or Gradle wrote no checksums"
  [ -d "$CHECK/$G_DIR" ] && ! find "$CHECK" -name '*.sha256' -o -name '*.sha512' | grep -q .; check \
    "the flag suppresses sha256 and sha512 everywhere" "a -D on the command line did not reach the publisher"
  if [ "$below_97" = true ]; then
    [ -f "$CHECK/$G_DIR/lib-1.0.0.jar.asc.md5" ]; check \
      "below 9.7, signatures still get md5 and sha1" "the version rule is wrong for this Gradle"
    grep -q 'files per artifact file: 6' "$tmp/checker.log"; check "six files per artifact file" "see the checker log" "$tmp/checker.log"
  else
    [ ! -f "$CHECK/$G_DIR/lib-1.0.0.jar.asc.md5" ]; check \
      "at 9.7 or later, signatures get no checksums" "the version rule is wrong for this Gradle"
    grep -q 'files per artifact file: 4' "$tmp/checker.log"; check "four files per artifact file" "see the checker log" "$tmp/checker.log"
  fi

  publish_check unsigned "$FLAG"
  check "the dry-run check publication runs without a key" \
    "the dry-run switch did not make signing optional" "$tmp/check.log"
  [ -d "$CHECK/$G_DIR" ] && ! find "$CHECK" -name '*.asc' | grep -q .; check "a dry run signs nothing" "a key reached the dry run"
  checker unsigned; check "the checker accepts a dry run" "see the checker log" "$tmp/checker.log"

  # The regression the check exists for: the flag no longer taking effect.
  publish_check signed ""
  check "the publication runs without the flag" "Gradle failed for another reason" "$tmp/check.log"
  checker signed; [ $? = 1 ] && grep -q '\.sha256 would be uploaded' "$tmp/checker.log"; check \
    "without the flag, the checker refuses the upload" "a real sha256 went unnoticed"

  # Everything routed away: Gradle skips every publish task and creates neither directory. The
  # guard warns and passes on this, so the check must too, not fail on the missing directories.
  rm -rf "$GUARD" "$CHECK" "$CHECK.gradle-version"
  ( cd "$fixture" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS=":fatJava, :libJava" ./gradlew publishToMavenLocal \
      -Pnexus=true -Dmaven.repo.local="$GUARD" --init-script "$NOSIGN" --init-script "$ROUTING" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false -s ) > "$tmp/guard.log" 2>&1
  check "the guard's publication runs with everything routed away" "publishToMavenLocal failed" "$tmp/guard.log"
  ( cd "$fixture" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS=":fatJava, :libJava" OCTOPUS_CHECKSUM_CHECK_REPO="$CHECK" \
      ./gradlew publishAllPublicationsToCentralChecksumCheckRepository -Pnexus=true "$FLAG" \
      --init-script "$INIT" --init-script "$ROUTING" --init-script "$NOSIGN" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false -s ) > "$tmp/check.log" 2>&1
  check "the check publication runs with everything routed away" "Gradle failed" "$tmp/check.log"
  checker unsigned; check "nothing bound for Central passes, as the guard does" \
    "see the checker log" "$tmp/checker.log"
  grep -q 'nothing to check' "$tmp/checker.log"; check "and says there was nothing to check" "the warning is missing"

  (cd "$fixture" && ./gradlew --stop >/dev/null 2>&1)
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
