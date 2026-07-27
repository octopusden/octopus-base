#!/usr/bin/env bash
# Scenarios for resolve-released-version.sh.
#
# git is replaced by the stub next to this file (put on PATH), so tag layouts that
# would need a crafted repository — several version tags on one commit, a higher
# unrelated tag elsewhere — are exercised directly.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../resolve-released-version.sh"

failures=0
checks=0

run() { # name expected_status expected_output env...
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

# An explicit version always wins, with or without the tag prefix.
run 'explicit version' 0 '^2\.5\.2$' EXPLICIT_VERSION=2.5.2 TAGS_AT_SHA='v1.0.0'
run 'explicit version with v prefix' 0 '^2\.5\.2$' EXPLICIT_VERSION=v2.5.2 TAGS_AT_SHA=''

# The normal path: exactly one version tag on the commit the release run built.
run 'single tag on the release commit' 0 '^2\.2\.37$' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='v2.2.37'

# The regression this replaced: a higher tag exists in the repository but points at
# a different commit, so it must not be picked. ALL_TAGS is deliberately populated
# with it — the stub fails the test if the script ever reads it.
run 'higher unrelated tag is ignored' 0 '^2\.2\.37$' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' ALL_TAGS='v9.9.9 v2.2.37'

# Non-semver tags on the same commit are not candidates.
run 'non-semver tags filtered out' 0 '^2\.2\.37$' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='latest v9.9.9-pr99 v2.2.37 release-2'

# Nothing was released from that commit: refuse rather than register a guess.
run 'no version tag on the commit' 1 'No vX\.Y\.Z tag points at' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='latest nightly'

# Ambiguity must be surfaced, not resolved silently.
run 'several version tags on one commit' 1 'Several version tags point at' \
  RELEASE_RUN_SHA=178e83a0 TAGS_AT_SHA='v2.2.37 v2.3.0'

# Called outside a release-run context and without an explicit version.
run 'no inputs at all' 1 'cannot be determined' TAGS_AT_SHA='v2.2.37'

echo
if [ "$failures" -eq 0 ]; then
  echo "All $checks scenarios passed."
else
  echo "$failures of $checks scenarios failed."
fi
exit $((failures > 0))
