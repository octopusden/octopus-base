#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/central-preflight-step.sh — the paths that decide
# whether the Central preflight runs at all.
#
# The consumer's Gradle wrapper is replaced by a fake `./gradlew` in a temp workspace, which
# is what makes the interesting cases reachable: a listing that exits non-zero, one that
# stalls past the timeout, one that writes nothing, and one that writes coordinates. repo1 is
# replaced by the stub curl next to this file.
#
# The property under test: none of those may fail the step. A release must run unless the
# preflight itself says the version is fully published — a listing that silently produced
# nothing must be reported, not swallowed and not fatal.
#
# Usage: bash .github/scripts/test/preflight-step-scenarios.sh   (from the repo root)

# shellcheck disable=SC2016
# The GRADLEW values below are single-quoted on purpose: they are the BODY of the fake
# wrapper, written to a file and expanded when that wrapper runs, not here. Expanding
# $OCTOPUS_COORDS_FILE at this point would write the empty string into the fixture.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
[ -f "$scripts/central-preflight-step.sh" ] || { echo "central-preflight-step.sh not found"; exit 1; }

pass=0; fail=0

# run <name> <expected-rc> <must-match> [<must-not-match>]
#   GRADLEW      body of the fake wrapper; it may write "$OCTOPUS_COORDS_FILE"
#   TIMEOUT      LISTING_TIMEOUT for the run
#   REPO1_CODES, EXPECT_COORDS, EXPECT_VERSION  as for the stub curl
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  export STATE_DIR RUNNER_TEMP
  STATE_DIR="$(mktemp -d)"; RUNNER_TEMP="$(mktemp -d)"
  local ws="$STATE_DIR/workspace"; mkdir -p "$ws"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -u'
    printf '%s\n' "${GRADLEW:-exit 0}"
  } > "$ws/gradlew"
  chmod +x "$ws/gradlew"

  # Unset and empty are different inputs here, and it is the UNSET one that used to exit 1
  # under `set -u`. So the assignment is OMITTED rather than emptied — `env -u VAR VAR=x`
  # would set it again, the assignment being processed after the -u.
  local -a envs=(-u BUILD_VERSION -u HELPER_DIR)
  [ "${UNSET_BUILD_VERSION:-}" = "1" ] || envs+=("BUILD_VERSION=${VERSION:-2.0.105}")
  [ "${UNSET_HELPER_DIR:-}" = "1" ] || envs+=("HELPER_DIR=${HELPER_OVERRIDE:-$scripts}")

  local out="$STATE_DIR/out.txt" rc ok=true
  ( cd "$ws" && PATH="$here/preflight:$PATH" env "${envs[@]}" \
      LISTING_TIMEOUT="${TIMEOUT:-300}" \
      DRY_RUN=false GITHUB_REPOSITORY= \
      REPO1_CODES="${REPO1_CODES:-404}" \
      EXPECT_COORDS="${EXPECT_COORDS:-org.octopusden.octopus:client}" \
      EXPECT_VERSION="${VERSION:-2.0.105}" \
      bash "$scripts/central-preflight-step.sh" ) >"$out" 2>&1
  rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
  fi
}

WRITES_ONE='printf "org.octopusden.octopus:client\n" > "$OCTOPUS_COORDS_FILE"'

# A missing timeout(1) made four of these pass for the wrong reason on the first run: the
# listing failed before the fake wrapper ran at all. Name it rather than let it happen again.
if command -v timeout >/dev/null 2>&1; then
  echo "timeout(1) present: the ceiling is exercised."
else
  echo "NOTE  timeout(1) is absent here, so the ceiling itself is not exercised; the stall"
  echo "      scenario below only checks that an unbounded listing still cannot fail the step."
fi

echo "-- the listing works -----------------------------------------------------"
GRADLEW="$WRITES_ONE" REPO1_CODES=404 \
  run "hands the listed coordinates to the preflight" 0 "the version is free"
GRADLEW="$WRITES_ONE" REPO1_CODES=404 \
  run "shows what would be published" 0 "Publications this release would publish"
GRADLEW="$WRITES_ONE" REPO1_CODES=200 \
  run "still stops when everything is published" 1 "already published on Maven Central"

echo "-- the listing passes the release version through -------------------------"
GRADLEW='[ "$OCTOPUS_RELEASE_VERSION" = "2.0.105" ] || { echo "wrong version: $OCTOPUS_RELEASE_VERSION"; exit 3; }
printf "org.octopusden.octopus:client\n" > "$OCTOPUS_COORDS_FILE"' \
  run "tells Gradle which version is being released" 0 "the version is free" "wrong version"
GRADLEW='case "$*" in *"list-publications.init.gradle"*) : ;; *) echo "no init script: $*"; exit 3 ;; esac
case "$*" in *-Pnexus=true*) : ;; *) echo "publications not shaped like the real upload: $*"; exit 3 ;; esac
printf "org.octopusden.octopus:client\n" > "$OCTOPUS_COORDS_FILE"' \
  run "applies the init script and the real upload's properties" 0 "the version is free" "no init script|not shaped"

echo "-- the listing fails, stalls, or produces nothing -------------------------"
GRADLEW='echo "BUILD FAILED: something in the consumer build"; exit 1' \
  run "proceeds and says so when Gradle exits non-zero" 0 "Publication listing failed"
GRADLEW='echo "BUILD FAILED: something in the consumer build"; exit 1' \
  run "shows the Gradle output when there are no coordinates" 0 "something in the consumer build"
if command -v timeout >/dev/null 2>&1; then
  GRADLEW='sleep 30' TIMEOUT=2 \
    run "proceeds when the listing stalls past its timeout" 0 "Publication listing failed"
else
  GRADLEW='sleep 1; printf "org.octopusden.octopus:client\n" > "$OCTOPUS_COORDS_FILE"' \
    run "runs the listing unbounded, and says so, without timeout(1)" 0 "listing is unbounded"
fi
GRADLEW='exit 0' \
  run "proceeds when the listing writes nothing at all" 0 "preflight skipped"
GRADLEW='printf "" > "$OCTOPUS_COORDS_FILE"' \
  run "proceeds when the listing writes an empty file" 0 "preflight skipped"

echo "-- an incomplete helper checkout ------------------------------------------"
HELPER_OVERRIDE="$(mktemp -d)" GRADLEW="$WRITES_ONE" \
  run "proceeds when the helper directory is missing its scripts" 0 "preflight skipped" "::error"

echo "-- inputs the caller always sets, and must not stop a release anyway ------"
# Neither is reachable from the workflow — HELPER_DIR is a literal there and BUILD_VERSION is
# a job-level env, so it is set-but-possibly-empty. That was equally true of the
# `BUILD_VERSION:?` that came out of central-preflight.sh, and it came out because "only the
# preflight's verdict may stop a release" is worth being literally true.
UNSET_HELPER_DIR=1 GRADLEW="$WRITES_ONE" WANT_REPO1_CALLS=0 \
  run "proceeds when no helper directory is passed" 0 "No helper directory was passed" "::error"
UNSET_BUILD_VERSION=1 GRADLEW="$WRITES_ONE" WANT_REPO1_CALLS=0 \
  run "proceeds when BUILD_VERSION is not even set" 0 "preflight skipped" "::error"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
