#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/check-central-checksums.py.
#
# The inputs are two directory trees, the throwaway file:// repository the check published into and
# the publication guard's routed local repository, so the fixtures are written here and no Gradle is
# needed. What Gradle really writes is central-checksum-fixture.sh's job; this suite covers the rule,
# and above all its refusals, which a real build cannot be made to produce on demand.
#
# The last block pins the workflow wiring the checker depends on: the flag on both uploads, and the
# check's gate and position. GitHub evaluates `if:`, so no scenario can exercise it.
#
# Usage: bash .github/scripts/test/central-checksum-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
SCRIPT="$root/.github/scripts/check-central-checksums.py"
[ -f "$SCRIPT" ] || { echo "check-central-checksums.py not found"; exit 1; }

pass=0; fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
G="org/fixture/lib/1.0.0"
FILES="lib-1.0.0.jar lib-1.0.0-sources.jar lib-1.0.0.pom"

# fixture <sidecars...> — the guard's view of three artifact files, and a check directory holding
# each of them with the given sidecars, plus metadata with md5 and sha1.
fixture() {
  rm -rf "$tmp/check" "$tmp/guard"
  mkdir -p "$tmp/check/$G" "$tmp/guard/$G"
  touch "$tmp/guard/org/fixture/lib/maven-metadata-local.xml"
  local f s
  for f in $FILES; do
    echo x > "$tmp/guard/$G/$f"
    echo x > "$tmp/check/$G/$f"
    for s in "$@"; do touch "$tmp/check/$G/$f$s"; done
  done
  touch "$tmp/check/org/fixture/lib/maven-metadata.xml" \
        "$tmp/check/org/fixture/lib/maven-metadata.xml.md5" \
        "$tmp/check/org/fixture/lib/maven-metadata.xml.sha1"
}

# run <name> <expected-rc> <must-match> [<must-not-match>]
run() {
  local name="$1" want="$2" match="$3" nomatch="${4:-}"
  python3 "$SCRIPT" "$tmp/check" "$tmp/guard" > "$tmp/out" 2>&1
  local rc=$? ok=1
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

echo "-- what Gradle writes with the flag is accepted ----------------------"
fixture .md5 .sha1 .asc .asc.md5 .asc.sha1
run "below Gradle 9.7, signed: 6 files per artifact file" 0 'no extra files' "$DET"
[ "$(grep -c "^  org/" "$tmp/out")" = 21 ]; check \
  "logs the full file list" "the log lists fewer than all 21 files, so the rollout has no complete evidence"
fixture .md5 .sha1 .asc
run "Gradle 9.7 or later, signed: 4 files per artifact file" 0 'no extra files'
fixture .md5 .sha1
run "unsigned, as the check runs" 0 'no extra files'
rm -rf "$tmp/check" "$tmp/guard"
run "everything routed away: Gradle creates neither directory" 0 'no extra files' "$DET"

echo "-- extra files are refused -------------------------------------------"
fixture .md5 .sha1 .sha256
run "a sha256 of an artifact" 1 "$DET"
fixture .md5 .sha1 .asc .asc.sha512
run "a sha512 of a signature" 1 'lib-1.0.0.jar.asc.sha512'
fixture .md5 .sha1
touch "$tmp/check/org/fixture/lib/maven-metadata.xml.sha256"
run "a sha256 of the metadata" 1 'maven-metadata.xml.sha256'
fixture .md5 .sha1
mkdir -p "$tmp/check/org/fixture/lib-fat/1.0.0"
touch "$tmp/check/org/fixture/lib-fat/1.0.0/lib-fat-1.0.0-all.jar"
run "an artifact the guard did not see (a routed publication leaking in)" 1 'lib-fat-1.0.0-all.jar'
fixture .md5 .sha1
rm -rf "$tmp/guard"
run "files with no guard view at all" 1 'lib-1.0.0.jar would be uploaded'

echo "-- the check must have seen what the guard saw ------------------------"
# Not "what Central needs" (the Portal validates that), but proof the check ran: a consumer build
# that filters publish tasks by repository skips every task bound for CentralChecksumCheck.
fixture .md5 .sha1
rm -rf "$tmp/check"
run "a guard view with no check directory: refused, not classified deterministic" 1 \
  'RELEASE_PUBLISH_CLASS=unknown' "$DET|no extra files"
fixture .md5 .sha1
rm "$tmp/check/$G/lib-1.0.0-sources.jar" "$tmp/check/$G/lib-1.0.0-sources.jar".*
run "an artifact file the check did not publish: refused" 1 'lib-1.0.0-sources.jar was not published' "$DET"
fixture .md5 .sha1 .sha256
rm "$tmp/check/$G/lib-1.0.0.pom" "$tmp/check/$G/lib-1.0.0.pom".*
run "extra files outrank missing ones: deterministic" 1 "$DET"

echo "-- the workflows are wired to it --------------------------------------"
FLAG='-Dorg.gradle.internal.publish.checksums.insecure=true'
REL="$root/.github/workflows/common-java-gradle-release.yml"
OWN="$root/.github/workflows/release-octopus-base.yml"
grep -E 'publishToSonatype closeSonatypeStagingRepository' "$REL" | grep -qF -- "$FLAG"; check \
  "the reusable workflow's upload passes the flag" "without it every consumer uploads sha256 and sha512"
grep -A6 './gradlew build publishToSonatype closeSonatypeStagingRepository' "$OWN" | grep -qF -- "$FLAG"; check \
  "the plugin release's upload passes the flag" "the plugin release uploads sha256 and sha512"

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
gate="$(grep -E '^ *if:' "$tmp/step")"
case "$gate" in *inputs.publish-to-nexus*"inputs.resume-deployment-id == ''"*) ! grep -q dry-run <<< "$gate" ;; *) false ;; esac; check \
  "the check runs on a fresh Central upload and on a dry run, never on a resume" \
  "its if: changed; a resume would check files this run did not upload, or a dry run would skip it"
for want in "$FLAG" publishAllPublicationsToCentralChecksumCheckRepository publication-routing.init.gradle \
            no-signing.init.gradle -Pnexus=true m2-publication-guard; do
  grep -qF -- "$want" "$tmp/step"; check "the check uses $want" "it checks a different build than the upload"
done
! grep -qE '(^|[^A-Za-z])publish( |$)' "$tmp/step"; check \
  "the check never runs the catch-all publish task" "'publish' also targets sonatype and GitHubPackages"
at() { grep -n "^ *- name: $2\$" "$1" | head -1 | cut -d: -f1; }
[ "$(at "$REL" 'Guard against publishing fat jars to Maven Central')" -lt "$(at "$REL" 'Check Central checksum files')" ] \
  && [ "$(at "$REL" 'Check Central checksum files')" -lt "$(at "$REL" 'Publish to Sonatype Nexus')" ]; check \
  "the check runs after the guard and before the upload" "it reads the guard's directory, and must stop the release before anything is staged"

awk '/^  central-checksum-check:/ { s = 1; next } s && /^  [a-z]/ { exit } s { print }' "$OWN" > "$tmp/own-job"
own_gate="$(grep -E '^    if:' "$tmp/own-job")"
case "$own_gate" in *"inputs.resume-deployment-id == ''"*) ! grep -q 'dry-run' <<< "$own_gate" ;; *) false ;; esac; check \
  "the plugin release checks every fresh upload, dry or real" "the check job lost its resume gate, or skips one of the modes"
# verify-octopus-test is skipped unless asked for, and GitHub propagates a skip down the needs chain
# to every job whose if: uses no status function. calculate-version survives it with always(); this
# job must too, or it is skipped on every release and the upload goes unchecked.
case "$own_gate" in *'!failure()'*'!cancelled()'*"needs.calculate-version.result == 'success'"*) true ;; *) false ;; esac; check \
  "the check job is not skipped when verify-octopus-test is" \
  "without a status function in its if:, a skipped verify-octopus-test skips the check on every release"
grep -qF 'contents: read' "$tmp/own-job" && grep -qF 'persist-credentials: false' "$tmp/own-job" \
  && ! grep -q 'secrets\.' "$tmp/own-job"; check \
  "the check job runs the target SHA's build with a read-only token and no secrets" \
  "a dry run accepts any SHA, and its build could use the workflow's write token"
awk '/^  publish-quality-plugin:/ { s = 1; next } s && /^  [a-z]/ { exit } s { print }' "$OWN" > "$tmp/own-publish"
grep -q '^      - central-checksum-check$' "$tmp/own-publish" && grep -q '!failure()' "$tmp/own-publish"; check \
  "the plugin upload waits for the check, and still runs on a resume" \
  "the upload no longer depends on the check, or a skipped check (a resume) skips the upload"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
