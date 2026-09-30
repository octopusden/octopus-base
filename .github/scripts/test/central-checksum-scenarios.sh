#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/check-central-checksums.py (octopus-base#238).
#
# The inputs are two directory trees — the throwaway file:// repository the check published into,
# and the publication guard's routed local repository — so the fixtures are written here and no
# Gradle is needed. What Gradle really writes is central-checksum-fixture.sh's job; this suite
# covers the rules, and above all the refusals, which a real build cannot be made to produce on
# demand.
#
# The last block pins the workflow wiring the checker depends on: the flag on both uploads, and
# the check step's gate and position. GitHub evaluates `if:`, so no scenario can exercise it.
#
# Usage: bash .github/scripts/test/central-checksum-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
SCRIPT="$root/.github/scripts/check-central-checksums.py"
[ -f "$SCRIPT" ] || { echo "check-central-checksums.py not found"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"
G="org/fixture/lib/1.0.0"
FILES="lib-1.0.0.jar lib-1.0.0-sources.jar lib-1.0.0-javadoc.jar lib-1.0.0.pom lib-1.0.0.module"

# fixture <gradle-version> <signed|unsigned> — a correct pair of trees, as Gradle writes them with
# the flag on: md5 + sha1 for every file, signatures when signed, and on Gradle below 9.7 md5 +
# sha1 of each signature too.
fixture() {
  local version="$1" signed="$2"
  rm -rf "$tmp/check" "$tmp/check.gradle-version" "$tmp/guard"
  mkdir -p "$tmp/check/$G" "$tmp/guard/$G"
  echo "$version" > "$tmp/check.gradle-version"
  local f
  for f in $FILES; do
    echo x > "$tmp/guard/$G/$f"
    echo x > "$tmp/check/$G/$f"
    touch "$tmp/check/$G/$f.md5" "$tmp/check/$G/$f.sha1"
    if [ "$signed" = signed ]; then
      touch "$tmp/check/$G/$f.asc"
      case "$version" in
        8.*|9.[0-6]|9.[0-6].*) touch "$tmp/check/$G/$f.asc.md5" "$tmp/check/$G/$f.asc.sha1" ;;
      esac
    fi
  done
  # The guard's local repository carries its own metadata; the check's remote-layout one sits a
  # level up, beside the version directories.
  touch "$tmp/guard/org/fixture/lib/maven-metadata-local.xml"
  touch "$tmp/check/org/fixture/lib/maven-metadata.xml" \
        "$tmp/check/org/fixture/lib/maven-metadata.xml.md5" \
        "$tmp/check/org/fixture/lib/maven-metadata.xml.sha1"
}

# run <name> <mode> <expected-rc> <must-match> [<must-not-match>]
run() {
  local name="$1" mode="$2" want="$3" match="$4" nomatch="${5:-}"
  CHECK_MODE="$mode" python3 "$SCRIPT" "$tmp/check" "$tmp/guard" > "$tmp/out" 2>&1
  local rc=$?
  local ok=1
  [ "$rc" = "$want" ] || ok=0
  grep -qE -- "$match" "$tmp/out" || ok=0
  if [ -n "$nomatch" ] && grep -qE -- "$nomatch" "$tmp/out"; then ok=0; fi
  if [ "$ok" = 1 ]; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name (rc=$rc, wanted $want; must match /$match/${nomatch:+, must not match /$nomatch/})"
    sed 's/^/    /' "$tmp/out"; fail=$((fail+1))
  fi
}

# check <name> <what-it-means-if-it-failed> — reads the status of the preceding command.
check() {
  local rc=$?
  if [ "$rc" = 0 ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 ($2)"; fail=$((fail+1)); fi
}

DET='RELEASE_PUBLISH_CLASS=deterministic'

echo "-- correct output is accepted ------------------------------------------"
fixture 9.4.1 signed
run "Gradle below 9.7, signed: six files per artifact file" signed 0 'files per artifact file: 6' "$DET"
[ "$(grep -c "^  org/" "$tmp/out")" = 33 ] && grep -qF "  $G/lib-1.0.0.jar.asc.sha1" "$tmp/out"; check \
  "logs the full manifest" "the log lists fewer than all 33 files, so the rollout has no complete evidence"
fixture 9.8.0 signed
run "Gradle 9.7 or later, signed: four files per artifact file" signed 0 'files per artifact file: 4' "$DET"
fixture 9.7 signed
run "a two-part 9.7 version counts as 9.7" signed 0 'files per artifact file: 4'
fixture 9.4.1 unsigned
run "dry run: no signatures, accepted" unsigned 0 'files per artifact file: 3' "$DET"
fixture 9.4.1 signed
run "dry run: signatures present are not held against it" unsigned 0 'OK'

echo "-- the flag stopped working -------------------------------------------"
fixture 9.4.1 signed
touch "$tmp/check/$G/lib-1.0.0.jar.sha256"
run "a sha256 of an artifact is refused" signed 1 "$DET" 'All checks passed'
fixture 9.4.1 signed
touch "$tmp/check/$G/lib-1.0.0.jar.asc.sha512"
run "a sha512 of a signature is refused" signed 1 'lib-1.0.0.jar.asc.sha512'
fixture 9.4.1 signed
touch "$tmp/check/org/fixture/lib/maven-metadata.xml.sha256"
run "a sha256 of the metadata is refused" signed 1 'maven-metadata.xml.sha256'
fixture 9.4.1 unsigned
touch "$tmp/check/$G/lib-1.0.0.pom.sha512"
run "a dry run refuses a sha512 too" unsigned 1 "$DET"

echo "-- what Central needs is missing --------------------------------------"
fixture 9.4.1 signed
rm "$tmp/check/$G/lib-1.0.0.pom.md5"
run "a missing md5 is refused" signed 1 'lib-1.0.0.pom.md5'
fixture 9.4.1 unsigned
rm "$tmp/check/$G/lib-1.0.0.jar.sha1"
run "a dry run refuses a missing sha1" unsigned 1 'lib-1.0.0.jar.sha1'
fixture 9.4.1 signed
rm "$tmp/check/$G/lib-1.0.0-javadoc.jar.asc"
run "a missing signature is refused on a real upload" signed 1 'lib-1.0.0-javadoc.jar.asc'
fixture 9.4.1 signed
rm "$tmp/check/$G/lib-1.0.0-sources.jar" "$tmp/check/$G/lib-1.0.0-sources.jar".*
run "a missing sources jar is refused" signed 1 'lib-1.0.0-sources.jar'

echo "-- Gradle 9.7 and later write no signature checksums ------------------"
fixture 9.8.0 signed
touch "$tmp/check/$G/lib-1.0.0.jar.asc.md5"
run "a signature checksum on 9.7+ is refused" signed 1 'lib-1.0.0.jar.asc.md5'

echo "-- the check directory is not what Central would receive --------------"
fixture 9.4.1 signed
mkdir -p "$tmp/check/org/fixture/lib-fat/1.0.0"
touch "$tmp/check/org/fixture/lib-fat/1.0.0/lib-fat-1.0.0-all.jar"
run "an artifact the guard did not see is refused" signed 1 'lib-fat-1.0.0-all.jar'
fixture 9.4.1 signed
rm -rf "$tmp/check" && mkdir -p "$tmp/check"
run "an empty check directory is refused" signed 1 "$DET"
fixture 9.4.1 signed
rm -rf "$tmp/guard"/* "$tmp/check"/*
run "nothing bound for Central warns and passes, as the guard does" signed 0 'nothing to check' "$DET"
fixture 9.4.1 signed
rm -rf "$tmp/guard"/*
run "an empty guard view with files in the check directory is refused" signed 1 'not in the guard'

echo "-- unusable input is not a verdict ------------------------------------"
fixture 9.4.1 signed
rm "$tmp/check.gradle-version"
run "no Gradle version: exits 2, not deterministic" signed 2 'gradle-version' "$DET"
fixture 9.4.1 signed
echo "banana" > "$tmp/check.gradle-version"
run "an unreadable Gradle version: exits 2" signed 2 'banana' "$DET"
fixture 9.4.1 signed
rm -rf "$tmp/guard" "$tmp/check"
run "neither directory, as Gradle leaves it when everything is routed away: passes" signed 0 'nothing to check' "$DET"
fixture 9.4.1 signed
rm -rf "$tmp/guard"
run "no guard directory while the check published files: refused" signed 1 'not in the guard'
fixture 9.4.1 signed
rm -rf "$tmp/check"
run "no check directory while the guard expects files: refused" signed 1 'is missing'
fixture 9.4.1 signed
run "an unknown mode: exits 2" maybe 2 'CHECK_MODE' "$DET"

echo "-- the workflows are wired to it --------------------------------------"
FLAG='-Dorg.gradle.internal.publish.checksums.insecure=true'
REL="$root/.github/workflows/common-java-gradle-release.yml"
OWN="$root/.github/workflows/release-octopus-base.yml"
grep -E 'publishToSonatype closeSonatypeStagingRepository' "$REL" | grep -qF -- "$FLAG"; check \
  "the reusable workflow's upload passes the flag" "without it every consumer uploads sha256 and sha512 again"
grep -A6 './gradlew build publishToSonatype closeSonatypeStagingRepository' "$OWN" | grep -qF -- "$FLAG"; check \
  "the plugin release's upload passes the flag" "the plugin release uploads sha256 and sha512 again"

# step <workflow> <step name> — prints the step, from its `- name:` to the next step at its indent.
step() {
  awk -v name="- name: $2" '
    { t = $0; sub(/^ +/, "", t) }
    t == name && !s { s = 1; ind = index($0, "-"); print; next }
    s && index($0, "- name:") == ind { exit }
    s && /^  [a-z]/ { exit }
    s { print }' "$1"
}
step "$REL" 'Check Central checksum files' > "$tmp/step"
[ -s "$tmp/step" ]; check "the reusable workflow has the check step" "no 'Check Central checksum files' step"
grep -E '^ *if:' "$tmp/step" | grep -qF "inputs.publish-to-nexus" \
  && grep -E '^ *if:' "$tmp/step" | grep -qF "inputs.resume-deployment-id == ''" \
  && ! grep -E '^ *if:' "$tmp/step" | grep -qF 'dry-run'; check \
  "the check runs on a fresh Central upload and on a dry run, never on a resume" \
  "its if: changed; a resume would check files this run did not upload, or a dry run would skip it"
grep -qF -- "$FLAG" "$tmp/step" && grep -qF 'publishAllPublicationsToCentralChecksumCheckRepository' "$tmp/step" \
  && grep -qF 'publication-routing.init.gradle' "$tmp/step" && grep -qF -- '-Pnexus=true' "$tmp/step"; check \
  "the check publishes the way the upload does" "the flag, the routing or -Pnexus=true is missing, so it checks a different build"
grep -qE '(^|[^A-Za-z])publish( |$)' "$tmp/step"; [ $? -ne 0 ]; check \
  "the check never runs the catch-all publish task" "'publish' also targets sonatype and GitHubPackages"
at() { grep -n "^ *- name: $2\$" "$1" | head -1 | cut -d: -f1; }
[ "$(at "$REL" 'Guard against publishing fat jars to Maven Central')" -lt "$(at "$REL" 'Check Central checksum files')" ] \
  && [ "$(at "$REL" 'Check Central checksum files')" -lt "$(at "$REL" 'Publish to Sonatype Nexus')" ]; check \
  "the check runs after the guard and before the upload" "it reads the guard's directory, and must stop the release before anything is staged"

step "$OWN" 'Check Central checksum files' > "$tmp/own-real"
grep -E '^ *if:' "$tmp/own-real" | grep -qF "inputs.resume-deployment-id == ''" \
  && grep -qF 'CHECK_MODE: signed' "$tmp/own-real"; check \
  "the plugin release checks a fresh upload, signed" "the real-upload check lost its resume gate or its signed mode"
[ "$(at "$OWN" 'Check Central checksum files')" -lt "$(at "$OWN" 'Build and publish plugin')" ]; check \
  "the plugin release checks before it uploads" "the check runs after the upload, when a finding can no longer stop it"
step "$OWN" 'Check Central checksum files (dry run)' > "$tmp/own-dry"
grep -qF 'CHECK_MODE: unsigned' "$tmp/own-dry"; check \
  "the plugin release checks a dry run too" "a dry run of the plugin release runs no Gradle at all without this job"
awk '/^  central-checksum-dry-run:/ { s = 1 } s && /^  [a-z]/ && !/central-checksum-dry-run/ { exit } s { print }' "$OWN" \
  > "$tmp/own-dry-job"
grep -qF "needs.flags.outputs.dry-run == 'true'" "$tmp/own-dry-job"; check \
  "the dry-run job is gated on the dry run" "the job runs on a real release too, or never"
grep -qF 'contents: read' "$tmp/own-dry-job" && grep -qF 'persist-credentials: false' "$tmp/own-dry-job"; check \
  "the dry-run job runs the target SHA's build with a read-only token it cannot find" \
  "a dry run accepts any SHA, and its build could push with the workflow's write token"

# The plugin workflow's two copies differ only in their env; the run body must stay identical, or
# one mode checks a different build than the other.
sed -n '/run: |/,/check-central-checksums.py/p' "$tmp/own-real" > "$tmp/own-real-run"
sed -n '/run: |/,/check-central-checksums.py/p' "$tmp/own-dry" > "$tmp/own-dry-run"
[ -s "$tmp/own-real-run" ] && cmp -s "$tmp/own-real-run" "$tmp/own-dry-run"; check \
  "the plugin release's two checks run the same body" "the real and dry-run copies drifted apart"

for f in "$tmp/step" "$tmp/own-real"; do
  grep -qF -- '-Dorg.gradle.configuration-cache=false' "$f"; check \
    "the configuration cache is off in $(basename "$f")" \
    "a reused cache entry skips the init script, so no Gradle version is recorded and the release stops"
done

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
