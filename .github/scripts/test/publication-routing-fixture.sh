#!/usr/bin/env bash
#
# Runs the release workflow's publication-routing init script against a REAL Gradle build.
#
# The script is read out of common-java-gradle-release.yml rather than kept beside this test, so
# what runs here is the same text the workflow writes — a copy would drift.
#
# The fixture publishes to file:// repositories, so the routing tasks execute for real instead of
# being inspected. That is the only way to catch the failure this test exists for: disabling a
# publish task does NOT drop its dependencies, so an aggregate over ALL publications still pulls
# the signing task of a publication it will not publish, and that task dies for want of a key.
# A --dry-run or an `enabled` check passes straight through that.
#
# Usage: bash .github/scripts/test/publication-routing-fixture.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
WORKFLOW="$root/.github/workflows/common-java-gradle-release.yml"
GRADLEW="$root/gradle-quality-plugin/gradlew"
[ -f "$WORKFLOW" ] || { echo "common-java-gradle-release.yml not found"; exit 1; }
[ -x "$GRADLEW" ] || { echo "no gradle wrapper at $GRADLEW"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"
INIT="$tmp/publication-routing.init.gradle"

# The heredoc body of the routing step. Groovy ignores leading whitespace, so the YAML block
# indentation is left in place rather than guessed at. The opening marker is matched exactly once
# and anchored on <<'GRADLE': `<<` is also a Groovy operator, so a looser match eats body lines.
awk '
  /- name: Prepare publication routing init script/ { instep = 1; next }
  instep && !inbody && /<<.GRADLE./ { inbody = 1; next }
  inbody && $1 == "GRADLE" { exit }
  inbody { print }
' "$WORKFLOW" > "$INIT"
[ -s "$INIT" ]; rc=$?
if [ "$rc" != 0 ]; then
  echo "FAIL  could not extract the init script from $WORKFLOW (step renamed, or the heredoc changed)"
  exit 1
fi
for marker in 'publishSelectedPublicationsToGitHubPackages' 'selected <<' 'GitHubPackages'; do
  grep -qF "$marker" "$INIT" || {
    echo "FAIL  extracted text is missing '$marker' — the extractor dropped a line or read the wrong heredoc"
    sed 's/^/    /' "$INIT"
    exit 1
  }
done

# Two publications and two repositories, so all four routing pairings exist. libJava is signed,
# because that is what puts a signing task on the graph of anything depending on its publish task
# — the regression being guarded against. `required = false` keeps it from failing the runs where
# libJava is SUPPOSED to publish; the GitHub Packages assertions check the task never appears at
# all, which is the condition that actually broke.
#
# The fixture also carries a buildSrc, because an init script applies to that build too and it
# publishes nothing: without a guard the routing check fails there before the real build runs.
# Every assertion below therefore exercises that path.
fixture="$tmp/fixture"
mkdir -p "$fixture/sub" "$fixture/buildSrc/src/main/groovy"
cat > "$fixture/buildSrc/build.gradle" <<'G'
plugins { id 'groovy-gradle-plugin' }
G
cat > "$fixture/settings.gradle" <<'G'
rootProject.name = 'routing-root'
include 'sub'
G
cat > "$fixture/build.gradle" <<'G'
allprojects {
    apply plugin: 'java'
    apply plugin: 'maven-publish'
    apply plugin: 'signing'
    group = "org.fixture.${project.name}"
    version = '9.9.9-fixture'
    publishing {
        publications {
            register('libJava', MavenPublication) { from components.java }
            register('fatJava', MavenPublication) {
                artifactId = "${project.name}-fat"
                artifact(tasks.jar) { classifier = 'all' }
            }
        }
        repositories {
            maven { name = 'GitHubPackages'; url = uri("${rootDir}/out-github") }
            maven { name = 'sonatype';       url = uri("${rootDir}/out-sonatype") }
        }
    }
    signing {
        required = false
        sign(publishing.publications['libJava'])
    }
}
G

# route <publications> <task> [extra args] -> Gradle output in $tmp/log
route() {
  local pubs="$1" task="$2"; shift 2
  rm -rf "$fixture/out-github" "$fixture/out-sonatype"
  ( cd "$root/gradle-quality-plugin" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS="$pubs" \
      ./gradlew --project-dir "$fixture" "$task" --init-script "$INIT" \
      -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false "$@" \
  ) > "$tmp/log" 2>&1
}

# check <name> <what-it-means-if-it-failed> — reads the status of the preceding command.
check() {
  local rc=$?
  if [ "$rc" = "0" ]; then echo "PASS  $1"; pass=$((pass+1)); else
    echo "FAIL  $1 ($2)"; fail=$((fail+1))
    echo "--- github repo:";   (cd "$fixture" && find out-github -type f 2>/dev/null | sort | sed 's/^/    /')
    echo "--- sonatype repo:"; (cd "$fixture" && find out-sonatype -type f 2>/dev/null | sort | sed 's/^/    /')
    echo "--- log tail:"; tail -n 25 "$tmp/log" | sed 's/^/    /'
  fi
}

echo "-- the selected publication, and only it, reaches GitHub Packages ---------"
route fatJava publishSelectedPublicationsToGitHubPackages
check "publishes without touching the unselected publication" \
  "this is the signing regression: an aggregate over ALL publications pulls libJava's sign task, which has no key"

[ -f "$fixture/out-github/org/fixture/routing-root/routing-root-fat/9.9.9-fixture/routing-root-fat-9.9.9-fixture-all.jar" ]; check \
  "uploads the selected publication's artifact" "the fat jar did not reach the GitHub Packages repository"
[ -f "$fixture/out-github/org/fixture/sub/sub-fat/9.9.9-fixture/sub-fat-9.9.9-fixture-all.jar" ]; check \
  "covers SUBPROJECTS too" "a subproject's publication was not routed — a hook walking only the root project would do this"
! find "$fixture/out-github" -name 'routing-root-9.9.9-fixture*' | grep -q .; check \
  "does not upload the unselected publication" "libJava reached GitHub Packages, where two publications sharing a coordinate collide on the POM"
! grep -q 'Task :signLibJavaPublication' "$tmp/log"; check \
  "never puts the unselected publication's signing task on the graph" \
  "signLibJavaPublication entered the graph — disabling a publish task does not drop its dependencies, and that task has no key in the release step"

echo "-- the selected publication is blocked from every other repository --------"
route fatJava publishAllPublicationsToSonatypeRepository
check "publishes to Sonatype with the fat publication disabled" "the Sonatype side failed outright"
! find "$fixture/out-sonatype" -name '*-all.jar' | grep -q .; check \
  "keeps the fat jar off Sonatype" "the fat jar reached the Sonatype repository — the one thing the routing exists to prevent"
[ -f "$fixture/out-sonatype/org/fixture/routing-root/routing-root/9.9.9-fixture/routing-root-9.9.9-fixture.jar" ]; check \
  "still publishes the thin jar to Sonatype" "the ordinary publication stopped working"

echo "-- a name matching no publication fails loudly ----------------------------"
route fatJvaTypo publishSelectedPublicationsToGitHubPackages
[ $? -ne 0 ] && grep -q 'No GitHubPackages publish task for publication' "$tmp/log"; check \
  "rejects an unknown publication name" "an unmatched name published nothing and said nothing, which is the silent failure this replaced"

echo "-- a blank input is a no-op ----------------------------------------------"
# Every repository that does not use this input gets the init script anyway, so it must change
# nothing for them.
route "" publishAllPublicationsToSonatypeRepository
check "leaves an unrelated build alone" "the init script broke a build that names no publications"
[ -f "$fixture/out-sonatype/org/fixture/routing-root/routing-root-fat/9.9.9-fixture/routing-root-fat-9.9.9-fixture-all.jar" ]; check \
  "disables nothing when no publications are named" "a publication was disabled despite a blank input"

echo "-- the Central guard does not see a routed publication --------------------"
# The guard publishes to mavenLocal and inspects what lands there, so a publication bound for
# GitHub Packages must not appear — otherwise it needs a fat-jar-publication-allowlist entry, and
# that list is keyed by artifactId, which the thin and fat publications of one module share.
guard="$tmp/guard-m2"
rm -rf "$guard"
( cd "$root/gradle-quality-plugin" && OCTOPUS_GITHUB_PACKAGES_PUBLICATIONS=fatJava \
    ./gradlew --project-dir "$fixture" publishToMavenLocal -Dmaven.repo.local="$guard" \
    --init-script "$INIT" \
    -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false \
) > "$tmp/log" 2>&1
check "publishes to mavenLocal with a publication routed away" "the guard's own invocation broke"
! find "$guard" -name '*-all.jar' 2>/dev/null | grep -q .; check \
  "keeps a routed publication out of the guard's view" \
  "the fat jar reached mavenLocal, so the guard counts it against Central and demands an allowlist entry"
find "$guard" -name 'routing-root-9.9.9-fixture.jar' 2>/dev/null | grep -q .; check \
  "still shows the Central-bound publication to the guard" \
  "the thin jar vanished too, so the guard would inspect nothing and pass everything"

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
