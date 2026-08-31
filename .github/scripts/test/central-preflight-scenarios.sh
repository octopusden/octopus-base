#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/central-preflight.sh.
#
# Maven Central and the GitHub API are replaced by the stubs in ./preflight (put on
# PATH), so every verdict — including the ones that need a specific mix of published and
# free coordinates, or a lookup that fails without saying 404 — runs offline and
# deterministically.
#
# The property under test is asymmetric and worth stating: the ONLY outcome that may stop
# a release is "every coordinate the upload would send is already on Central". Everything
# inconclusive must proceed, because this check exists to save a doomed build, never to
# become a new way for a workable release not to run.
#
# Usage: bash .github/scripts/test/central-preflight-scenarios.sh   (from the repo root)

# The script under test runs under the SAME interpreter as this suite ($BASH), not whatever
# `bash` resolves to on PATH: parameter expansion differs between bash 3.2 and bash 5, and a
# suite that silently ran the newer one would not be testing the interpreter it was invoked with.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../central-preflight.sh"
[ -f "$SCRIPT" ] || { echo "central-preflight.sh not found next to the test dir"; exit 1; }

pass=0; fail=0

# run <name> <expected-rc> <must-match> [<must-not-match>]
# Scenario knobs are passed by the caller as environment variables (see the stubs).
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  export STATE_DIR RUNNER_TEMP
  STATE_DIR="$(mktemp -d)"; RUNNER_TEMP="$(mktemp -d)"

  local coords="$RUNNER_TEMP/coords.txt"
  if [ "${NO_COORDS_FILE:-}" = "1" ]; then
    coords="$RUNNER_TEMP/absent.txt"
  elif [ "${UNTERMINATED:-}" = "1" ]; then
    # No trailing newline: `read` returns non-zero on the last line, so a loop that tests
    # only its exit status silently drops that coordinate.
    printf '%s' "${COORDS-org.octopusden.octopus:client}" > "$coords"
  else
    printf '%s\n' "${COORDS-org.octopusden.octopus:client}" > "$coords"
  fi

  # Computed rather than expanded inline: "empty on purpose" and "unset, use the default"
  # are different things, and a nested parameter expansion cannot express both.
  local bv="${VERSION:-2.0.105}"
  [ "${NO_VERSION:-}" = "1" ] && bv=""

  local out="$STATE_DIR/out.txt" rc ok=true
  PATH="$here/preflight:$PATH" env \
    BUILD_VERSION="$bv" \
    COORDS_FILE="$coords" \
    DRY_RUN="${DRY:-false}" \
    PREFLIGHT_BUDGET="${BUDGET:-90}" \
    GITHUB_REPOSITORY="${REPO-octopusden/octopus-external-systems-client}" \
    REPO1_CODES="${REPO1_CODES:-404}" \
    EXPECT_COORDS="${COORDS-org.octopusden.octopus:client}" \
    EXPECT_VERSION="${VERSION:-2.0.105}" \
    TAG_STATE="${TAG_STATE:-no}" RELEASE_STATE="${RELEASE_STATE:-no}" \
    "${BASH:-bash}" "$SCRIPT" >"$out" 2>&1
  rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if [ -n "${WANT_REPO1_CALLS:-}" ]; then
    # No `|| echo 0`: with the file present and no match, grep -c prints 0 and exits 1, so
    # the fallback would fire too and n would become two lines.
    local n=0
    [ -f "$STATE_DIR/calls.log" ] && n=$(grep -c 'maven2' "$STATE_DIR/calls.log")
    [ "$n" = "$WANT_REPO1_CALLS" ] || { ok=false; echo "  repo1 calls=$n expected=$WANT_REPO1_CALLS"; }
  fi
  # Only the status code is read, so a body must never be requested. Asserted on every
  # scenario rather than in one of its own: a regression to GET would otherwise stay green.
  if [ -s "$STATE_DIR/calls.log" ] && grep -qv '^HEAD ' "$STATE_DIR/calls.log"; then
    ok=false; echo "  a repo1 request was not a HEAD:"; sed 's/^/    /' "$STATE_DIR/calls.log"
  fi
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
  fi
}

TWO_COORDS='org.octopusden.octopus:client
org.octopusden.octopus:teamcity-client'

echo "-- the version is free ---------------------------------------------------"
REPO1_CODES=404 \
  run "starts the release when Central holds nothing" 0 "the version is free" "::error"
COORDS="$TWO_COORDS" REPO1_CODES="404 404" WANT_REPO1_CALLS=2 \
  run "checks every coordinate, not just the first" 0 "the version is free" "::error"

echo "-- the version is fully published (the only stopping verdict) -------------"
REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=yes \
  run "stops when published and already recorded (#195)" 1 "Version already released" "Version published but not recorded"
REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=yes \
  run "classifies the stop as deterministic" 1 "RELEASE_PUBLISH_CLASS=deterministic"
REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=yes \
  run "says the retry cannot help" 1 "RELEASE_PUBLISH_RETRYABLE=false"
REPO1_CODES=200 TAG_STATE=no RELEASE_STATE=no \
  run "stops with the recovery when published but unrecorded (#189)" 1 "Version published but not recorded" "could not be determined"
REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=no \
  run "treats a tag without a release as unrecorded" 1 "octopus-base#189"
REPO1_CODES=200 TAG_STATE=fail RELEASE_STATE=yes \
  run "does not read a failed tag lookup as absent" 1 "could not be determined" "published but not recorded"
COORDS="$TWO_COORDS" REPO1_CODES="200 200" TAG_STATE=yes RELEASE_STATE=yes \
  run "stops only after every coordinate answers present" 1 "all 2 coordinate"

echo "-- inconclusive: must proceed --------------------------------------------"
COORDS="$TWO_COORDS" REPO1_CODES="200 404" WANT_REPO1_CALLS=2 \
  run "proceeds on a partial overlap, saying why" 0 "partially on Maven Central" "::error"
REPO1_CODES=500 \
  run "proceeds when Central does not answer" 0 "inconclusive" "::error"
COORDS="$TWO_COORDS" REPO1_CODES="200 000" \
  run "proceeds when one coordinate is unanswered, even with another published" 0 "inconclusive" "::error"
COORDS="$TWO_COORDS" REPO1_CODES="000 200" WANT_REPO1_CALLS=1 \
  run "stops asking once the verdict is already inconclusive" 0 "already inconclusive" "::error"
REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=yes \
  run "does not call a tagged release complete without the log" 1 "octopus-release-log"
COORDS="$TWO_COORDS" BUDGET=0 WANT_REPO1_CALLS=0 \
  run "stops asking once its time budget is spent, and proceeds" 0 "budget for this check is spent" "::error"
COORDS="$TWO_COORDS" BUDGET=0 \
  run "says the budget is why the answer is missing" 0 "within this check's 0s budget"
NO_COORDS_FILE=1 \
  run "proceeds when the publication set could not be listed" 0 "preflight skipped" "::error"
COORDS="" \
  run "proceeds on an empty coordinate list" 0 "preflight skipped" "::error"
COORDS='not-a-coordinate
org.octopusden.octopus:client' REPO1_CODES=404 WANT_REPO1_CALLS=1 \
  run "ignores an unusable line and checks the rest" 0 "Ignoring 'not-a-coordinate'"
COORDS="org.octopusden.octopus:client:2.0.105" WANT_REPO1_CALLS=0 \
  run "refuses a coordinate that still carries a version" 0 "Ignoring 'org.octopusden.octopus:client:2.0.105'"
COORDS='org.octopusden.octopus:../../evil' WANT_REPO1_CALLS=0 \
  run "refuses a coordinate that could escape the repo1 path" 0 "Ignoring"
COORDS=":" \
  run "proceeds when every coordinate was unusable" 0 "preflight skipped"

echo "-- inputs that used to stop the release ----------------------------------"
# The two paths the review found unpinned. Both are guarded upstream and neither is
# reachable from the release workflow today; they are pinned because "no verdict other than
# all-published may stop a release" is the property this whole step is built on, and an
# unpinned exception to it is one refactor away from becoming real.
NO_VERSION=1 WANT_REPO1_CALLS=0 \
  run "proceeds when no release version was passed" 0 "No release version was passed" "::error"
COORDS='org.octopusden.octopus:client' UNTERMINATED=1 REPO1_CODES=404 WANT_REPO1_CALLS=1 \
  run "reads a final line with no trailing newline" 0 "the version is free" "::error"

echo "-- dry run reports, never fails ------------------------------------------"
DRY=true REPO1_CODES=200 TAG_STATE=yes RELEASE_STATE=yes \
  run "warns instead of stopping under dry-run" 0 "a real release would stop here" "::error"

echo "-- no GitHub context -----------------------------------------------------"
REPO='' REPO1_CODES=200 \
  run "still stops without a repository to ask about the tag" 1 "could not be determined"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
