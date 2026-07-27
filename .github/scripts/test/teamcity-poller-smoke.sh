#!/usr/bin/env bash
# Runs the TeamCity release poller far enough to exercise its HTTP client, then
# asserts that it aborted before dispatching anything.
#
# Why this exists next to the compile check: compiling the script and running it
# with no arguments stops at the argument guard, so the network is never touched.
# The breakage this guards against was purely a runtime one — the previous HTTP
# library reflected into java.net internals, which JDK 17+ forbids, so the script
# compiled and started perfectly and then died on its first request. Only a run
# that reaches a real request can catch that class of failure.
#
# Safety: the module name cannot exist and the token is invalid, so the first call
# (listing existing runs) fails and the script aborts *before* the dispatch POST.
# The assertions below verify exactly that, so this can never create a release.
set -uo pipefail

KOTLINC="${KOTLINC:-$HOME/kotlinc/bin/kotlinc}"
MAIN_KTS_JAR="${MAIN_KTS_JAR:-$HOME/kotlinc/lib/kotlin-main-kts.jar}"
SCRIPT="${1:-teamcity/scripts/CallGitHubRelease.main.kts}"

if [ ! -f "$KOTLINC" ]; then
  echo "Kotlin compiler not found at $KOTLINC" >&2
  exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "Script not found: $SCRIPT" >&2
  exit 1
fi

java -version 2>&1 | head -1

out="$("$KOTLINC" -cp "$MAIN_KTS_JAR" -script "$SCRIPT" -- \
  octopus-nonexistent-poller-probe \
  not-a-real-token \
  0000000000000000000000000000000000000000 \
  0.0.0-probe \
  1 \
  release 2>&1)"
rc=$?

echo "$out"
echo "exit code: $rc"

status=0
fail() { echo "SMOKE FAIL: $1" >&2; status=1; }

# The script must have reached and completed real HTTP requests, then given up.
grep -q 'Could not snapshot existing runs (attempt 1/3)' <<<"$out" \
  || fail "the first HTTP request never completed — the client did not run"
grep -q 'Could not snapshot existing workflow runs before dispatching' <<<"$out" \
  || fail "did not abort with the expected pre-dispatch message"
[ "$rc" -eq 3 ] || fail "expected exit code 3 (TeamCity build problem), got $rc"

# Nothing may have been created, and no JVM-level breakage may be hidden in the log.
if grep -q 'Release dispatched' <<<"$out"; then
  fail "a dispatch was sent — the probe must never reach that point"
fi
if grep -qE 'InaccessibleObjectException|Exception in thread|^error:' <<<"$out"; then
  fail "the script crashed instead of handling the failure"
fi

if [ "$status" -eq 0 ]; then
  echo "SMOKE OK: HTTP client ran on this JDK, failure handled, nothing dispatched"
fi
exit "$status"
