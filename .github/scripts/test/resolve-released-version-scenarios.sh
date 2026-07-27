#!/usr/bin/env bash
# Scenarios for resolve-released-version.sh.
#
# git and gh are replaced by the stubs next to this file (put on PATH), so tag layouts
# that would otherwise need a crafted repository — several version tags on one commit, a
# higher unrelated tag elsewhere, a release cut from a commit the run never reported —
# are exercised directly. Each stub answers exactly one invocation and exits 99 on
# anything else, so a future change that reaches for the full tag list, or for another
# API call, fails this suite instead of passing quietly.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../resolve-released-version.sh"

failures=0
checks=0

run() { # name expected_status expected_output_regex env...
  local name="$1" want_status="$2" want_out="$3"
  shift 3
  checks=$((checks + 1))
  local out status
  out="$(PATH="$here:$PATH" env "$@" bash "$script" 2>&1)"
  status=$?
  if [ "$status" -ne "$want_status" ]; then
    echo "FAIL [$name]: expected exit $want_status, got $status"
    echo "       output: $out"
    failures=$((failures + 1))
    return
  fi
  if ! grep -qE "$want_out" <<<"$out"; then
    echo "FAIL [$name]: output did not match /$want_out/"
    echo "       output: $out"
    failures=$((failures + 1))
    return
  fi
  echo "ok   [$name]"
}

common=(GITHUB_REPOSITORY=octopusden/octopus-test GH_TOKEN=stub)

# Source 1 — what the caller says, with or without the tag prefix.
run 'explicit version' 0 '2\.5\.2' EXPLICIT_VERSION=2.5.2 TAGS_AT_SHA='v1.0.0' "${common[@]}"
run 'explicit version with v prefix' 0 '2\.5\.2' EXPLICIT_VERSION=v2.5.2 TAGS_AT_SHA='' "${common[@]}"
run 'explicit garbage is rejected' 1 'not a version number' EXPLICIT_VERSION=latest "${common[@]}"

# Source 2 — exactly one version tag on the commit the run reported.
run 'single tag on the reported commit' 0 '2\.2\.37' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"
run 'non-semver tags are not candidates' 0 '2\.2\.37' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='latest v9.9.9-pr99 v2.2.37 release-2' "${common[@]}"

# The bug this replaced: a higher tag exists elsewhere in the repository. It must never
# win — not through the tag list (the stub rejects any call that asks for it) and not
# through the latest release, which is ordered by creation time, so an older canary
# loses to a newer real release.
run 'higher unrelated tag never wins' 0 '2\.2\.37' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' LATEST_RELEASE_TAG=v9.9.9 "${common[@]}"

# Source 3 — the reported commit cannot answer, so fall back to the newest release. This
# is the hybrid-flow case: the run reports the default branch tip while the release was
# cut from, and tagged on, a different commit.
run 'no tag on the reported commit falls back' 0 '2\.2\.37' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"
run 'several tags on one commit fall back' 0 '2\.2\.36' \
  RELEASE_RUN_SHA=cdfdd24d TAGS_AT_SHA='v2.2.35 v2.2.36' LATEST_RELEASE_TAG=v2.2.36 "${common[@]}"
run 'fallback explains itself' 0 'most recently created release' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"

# Nothing can answer: fail with something actionable rather than registering a guess.
run 'no tag and no readable release' 1 'Pass release-version explicitly' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_FAILS=1 "${common[@]}"
run 'no tag and no release at all' 1 'Pass release-version explicitly' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=null "${common[@]}"
run 'latest release is not a version tag' 1 'not a plain version number' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=nightly-2026-07-27 "${common[@]}"
run 'no repository to look up' 1 'repository is unknown' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' GH_TOKEN=stub

echo
if [ "$checks" -eq 0 ]; then
  echo "No scenarios ran — the suite would have passed vacuously." >&2
  exit 1
fi
if [ "$failures" -eq 0 ]; then
  echo "All $checks scenarios passed."
else
  echo "$failures of $checks scenarios failed."
fi
exit $((failures > 0))
