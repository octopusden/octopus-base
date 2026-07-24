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
common_env=(SEARCH_DEADLINE=3 VALIDATE_DEADLINE=6 PUBLISH_DEADLINE=6 CENTRAL_DEADLINE=6 SETTLE_SECONDS=1
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
    RESUME_DEPLOYMENT_ID="${RESUME_ID:-}" REQUIRE_COORDS="${REQ_COORDS:-}" \
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
