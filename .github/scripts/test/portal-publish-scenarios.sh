#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/portal-publish.sh.
#
# The Central Portal API is replaced by the stub `curl` next to this file (put on
# PATH), so the whole publish state machine — including paths that are impossible
# to trigger on demand against the live service (FAILED validation, ambiguous
# publish responses, wrong deployment ids) — runs offline and deterministically.
#
# Usage: bash .github/scripts/test/portal-publish-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../portal-publish.sh"
[ -f "$SCRIPT" ] || { echo "portal-publish.sh not found next to the test dir"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

pass=0; fail=0
# Short deadlines/settling so the suite runs in seconds.
common_env=(SEARCH_DEADLINE=3 VALIDATE_DEADLINE=60 PUBLISH_DEADLINE=6 CENTRAL_DEADLINE=6 SETTLE_SECONDS=1
            MAVEN_USERNAME=u MAVEN_PASSWORD=p)

# run <name> <expected-rc> <must-match> [<must-not-match>]
# Scenario knobs are passed by the caller as environment variables (see stub curl).
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  export STATE_DIR RUNNER_TEMP
  STATE_DIR="$(mktemp -d)"; RUNNER_TEMP="$(mktemp -d)"
  if [ "${NO_LOG:-}" != "1" ]; then
    printf "Created staging repository '%s' at https://x/content/\n" "${LOG_REPO:-org.octopusden--abc}" > "$RUNNER_TEMP/publish.log"
  fi
  local out="$STATE_DIR/out.txt" rc ok=true
  PATH="$here:$PATH" env "${common_env[@]}" \
    BUILD_VERSION="${VERSION:-2.5.0}" STAGING_PROFILE_ID="${SPI-org.octopusden}" \
    PUBLISH_LOG="$RUNNER_TEMP/publish.log" \
    RESUME_DEPLOYMENT_ID="${RESUME_ID:-}" REQUIRE_COORDS="${REQ_COORDS:-}" RELEASE_FLOW="${FLOW:-}" PUBLISH_POLL_SECONDS="${POLL:-1}" \
    bash "$SCRIPT" >"$out" 2>&1
  rc=$?
  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
  fi
}

echo "-- happy path and guards -------------------------------------------------"
STATUS_STATES="VALIDATING VALIDATED PUBLISHED" PUBLISH_CODES=204 REPO1_CODES=200 \
  run "publishes and verifies on Central" 0 "RELEASE_PUBLISH_CLASS=published" "Deterministic|Resumable"
STATUS_STATES="VALIDATED" STATUS_VERSION=9.9.9 \
  run "refuses a deployment of another version" 1 "refusing to publish" "POST .*/publisher/deployment"
STATUS_STATES="VALIDATED" STATUS_GROUP=com.evil \
  run "refuses a group outside the namespace" 1 "outside namespace" "POST .*/publisher/deployment"
STATUS_STATES="VALIDATED" REQ_COORDS="org.octopusden.octopus:absent" \
  run "refuses when a required coordinate is missing" 1 "required coordinate" "POST .*/publisher/deployment"
STATUS_STATES="VALIDATED PUBLISHED" PUBLISH_CODES=204 REPO1_CODES=200 \
  REQ_COORDS="org.octopusden.octopus-quality:org.octopusden.octopus-quality.gradle.plugin" \
  run "accepts the required marker coordinate" 0 "RELEASE_PUBLISH_CLASS=published"

echo "-- validation and publish edge cases -------------------------------------"
STATUS_STATES="VALIDATING FAILED" STATUS_ERRORS="missing signature" \
  run "reports validation errors as deterministic" 1 "missing signature"
STATUS_STATES="VALIDATED PUBLISHING PUBLISHED" PUBLISH_CODES="000" REPO1_CODES=200 \
  run "reconciles an inconclusive publish without re-POSTing" 0 "inconclusive response"
STATUS_STATES="VALIDATED PUBLISHING PUBLISHED" PUBLISH_CODES="409" REPO1_CODES=200 \
  run "treats a late 409 as already-published" 0 "RELEASE_PUBLISH_CLASS=published"
STATUS_STATES="VALIDATED VALIDATED VALIDATED VALIDATED VALIDATED" PUBLISH_CODES="409" \
  run "keeps a still-VALIDATED 409 deterministic" 1 "still VALIDATED"
STATUS_STATES="VALIDATED PUBLISHED" PUBLISH_CODES=204 REPO1_CODES="404" \
  run "stays resumable when Central never serves the artifact" 1 "RELEASE_PUBLISH_CLASS=resumable"

echo "-- Portal lags repo1 while PUBLISHING -------------------------------------"
# Central copies a version directory file by file, so the shortcut needs every required file.
# Default stub deployment: one jar GAV and the Gradle plugin marker (pom).
export STATUS_STATES="VALIDATED PUBLISHING" PUBLISH_CODES=204
OK_RE="confirmed via repo1 while Portal still said PUBLISHING"
NO_RE="confirmed via repo1|RELEASE_PUBLISH_CLASS=published"
TIMEOUT_RE="did not reach PUBLISHED"
run "everything served: confirmed via repo1, whatever Portal says" 0 "$OK_RE" "Resumable|RELEASE_PUBLISH_CLASS=resumable"
REPO1_MISSING_SUFFIX=.jar run "jar missing: times out" 1 "$TIMEOUT_RE" "$NO_RE"
REPO1_MISSING_SUFFIX=-sources.jar run "sources missing: times out" 1 "$TIMEOUT_RE" "$NO_RE"
REPO1_MISSING_SUFFIX=-javadoc.jar run "javadoc missing for packaging jar: times out" 1 "$TIMEOUT_RE" "$NO_RE"
REPO1_MISSING_SUFFIX=.pom.asc run "a missing pom signature (also the marker GAV's): times out" 1 "$TIMEOUT_RE" "$NO_RE"
REPO1_CODES=000 run "a repo1 transport error means not yet, not a failed job" 1 "$TIMEOUT_RE" "confirmed via repo1"

echo "-- packaging is read from the pom ---------------------------------------"
POM_PACKAGING=pom REPO1_MISSING_SUFFIX=.jar run "pom packaging needs only the pom and its signature" 0 "$OK_RE"
POM_PACKAGING=none REPO1_MISSING_SUFFIX=-javadoc.jar run "no <packaging> means jar" 1 "$TIMEOUT_RE" "$NO_RE"
POM_STYLE=comment REPO1_MISSING_SUFFIX=.jar run "a commented-out <packaging>pom</packaging> is ignored" 1 "$TIMEOUT_RE" "$NO_RE"
POM_STYLE=notproject REPO1_MISSING_SUFFIX=-javadoc.jar run "a root element that is not <project> counts as jar" 1 "$TIMEOUT_RE" "$NO_RE"
POM_STYLE=nested REPO1_MISSING_SUFFIX=.jar run "a <packaging> nested in plugin config is ignored" 1 "$TIMEOUT_RE" "$NO_RE"
POM_STYLE=truncated REPO1_MISSING_SUFFIX=-javadoc.jar run "an unparsable pom counts as jar" 1 "$TIMEOUT_RE" "$NO_RE"
POM_CURL_FAIL=1 run "a pom GET cut off after a 200 is not trusted" 1 "$TIMEOUT_RE" "$NO_RE"
POM_STYLE=injection run "a packaging with a workflow command is not echoed and switches the shortcut off" 1 \
  "$TIMEOUT_RE" "^::error title=x|confirmed via repo1"
POM_PACKAGING=war run "packaging war: no shortcut, waits for PUBLISHED" 1 "packaging 'war'" "$NO_RE"
for pk in maven-plugin bundle; do
POM_PACKAGING=$pk REPO1_MISSING_SUFFIX=-javadoc.jar run "$pk needs no javadoc: confirmed via repo1" 0 "$OK_RE"
done
# Gradle writes this marker into the pom of a module that also has a .module file.
POM_STYLE=gradle REPO1_MISSING_SUFFIX=.module run "Gradle marker in the pom: .module is awaited" 1 "$TIMEOUT_RE" "$NO_RE"
REPO1_MISSING_SUFFIX=.module run "without the marker .module is not awaited" 0 "$OK_RE"

# The GAV set of octopus-jira-api-plugin 2.1.2 (octopus-base#250): a pom module, two jar modules
# with javadoc, and an atlassian-plugin module that Central accepted without a javadoc jar.
export VERSION=2.1.2 STATUS_VERSION=2.1.2 STATUS_GROUP=org.octopusden.octopus.jira \
  STATUS_GAVS="octopus-jira-api octopus-jira-api-client octopus-jira-api-common octopus-jira-api-plugin" \
  POM_PACKAGING_BY="octopus-jira-api=pom octopus-jira-api-plugin=atlassian-plugin"
REPO1_MISSING_SUFFIX=octopus-jira-api-plugin-2.1.2-javadoc.jar \
  run "octopus-jira-api-plugin 2.1.2 (atlassian-plugin, no javadoc): confirmed via repo1" 0 "$OK_RE"
REPO1_MISSING_SUFFIX=octopus-jira-api-plugin-2.1.2-sources.jar \
  run "atlassian-plugin still requires its sources" 1 "$TIMEOUT_RE" "$NO_RE"
# The #250 bug class: a jar GAV next to an atlassian-plugin GAV keeps its javadoc requirement.
REPO1_MISSING_SUFFIX=octopus-jira-api-client-2.1.2-javadoc.jar \
  run "a plain jar GAV next to an atlassian-plugin still requires its javadoc" 1 "$TIMEOUT_RE" "$NO_RE"
unset VERSION STATUS_VERSION STATUS_GROUP STATUS_GAVS POM_PACKAGING_BY STATUS_STATES PUBLISH_CODES

# Phase 3 refuses an empty purl list; repo1_serves_all also refuses it (defence in depth).
STATUS_NOPURLS=1 run "an empty purl list is refused before the repo1 shortcut" 1 "No Maven coordinates" "confirmed via repo1"

echo "-- the shortcut stays tied to this deployment ----------------------------"
STATUS_STATES="VALIDATED PUBLISHING FAILED" PUBLISH_CODES=204 \
  run "repo1 complete but Portal now says FAILED: no success" 1 "re-check\) -> HTTP 200 state=FAILED" "RELEASE_PUBLISH_CLASS=published"
POLL=00 STATUS_STATES="VALIDATED PUBLISHED" \
  run "rejects a zero PUBLISH_POLL_SECONDS" 1 "PUBLISH_POLL_SECONDS must be a positive integer"

echo "-- recovery hints per flow -------------------------------------------------"
FLOW=maven RESUME_ID=dep-42 NO_LOG=1 STATUS_STATES="PUBLISHING" REPO1_CODES=404 \
  run "maven: Re-run failed jobs, and do not restart from the external CI" 1 \
  "Re-run failed jobs.*Do not restart the release from the external system" "resume-deployment-id"
RESUME_ID=dep-42 NO_LOG=1 STATUS_STATES="PUBLISHING" REPO1_CODES=404 \
  run "RELEASE_FLOW unset: resume-deployment-id, and do not restart from the external CI" 1 \
  "Re-dispatch with resume-deployment-id=dep-42.*Do not restart the release from the external system" "Re-run failed jobs"
FLOW=gradle RESUME_ID=dep-42 NO_LOG=1 STATUS_STATES="PUBLISHING" REPO1_CODES=404 \
  run "RELEASE_FLOW=gradle: resume-deployment-id" 1 "Re-dispatch with resume-deployment-id=dep-42" "Re-run failed jobs"

echo "-- resume, namespaces and staging bookkeeping ----------------------------"
RESUME_ID=dep-42 NO_LOG=1 STATUS_STATES="VALIDATED PUBLISHED" PUBLISH_CODES=204 REPO1_CODES=200 \
  run "resumes an existing deployment without uploading" 0 "Resuming deployment dep-42"
SPI="" STATUS_STATES="VALIDATED PUBLISHED" PUBLISH_CODES=204 REPO1_CODES=200 \
  run "works without a namespace (auto-lookup contract)" 0 "namespace check skipped" "outside namespace"
SEARCH_DID="-" STATUS_STATES="VALIDATED" \
  run "reports resumable when no Portal deployment appears" 1 "RELEASE_PUBLISH_COMPAT_KEY"
NO_LOG=1 \
  run "refuses when nothing was staged" 1 "PUBLISH_LOG is required|nothing was staged"

# Two staged repositories in one build must not be silently truncated.
export STATE_DIR RUNNER_TEMP; STATE_DIR="$(mktemp -d)"; RUNNER_TEMP="$(mktemp -d)"
printf "Created staging repository 'org.octopusden--a'\nCreated staging repository 'org.octopusden--b'\n" > "$RUNNER_TEMP/publish.log"
PATH="$here:$PATH" env "${common_env[@]}" BUILD_VERSION=2.5.0 STAGING_PROFILE_ID=org.octopusden \
  PUBLISH_LOG="$RUNNER_TEMP/publish.log" bash "$SCRIPT" >"$STATE_DIR/out.txt" 2>&1
if [ $? = 1 ] && grep -q "publishes exactly one" "$STATE_DIR/out.txt"; then
  echo "PASS  refuses a build that staged two repositories"; pass=$((pass+1))
else
  echo "FAIL  refuses a build that staged two repositories"; fail=$((fail+1)); sed 's/^/    | /' "$STATE_DIR/out.txt"
fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" = 0 ]
