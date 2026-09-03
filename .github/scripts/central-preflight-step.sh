#!/usr/bin/env bash
#
# The body of the release workflow's Central preflight step: list the Maven publication
# coordinates with Gradle, then hand them to central-preflight.sh.
#
# In a script rather than inline in the workflow because the paths that decide whether the
# check runs AT ALL are the ones worth testing. A listing that fails, stalls, or writes
# nothing must leave the release running and must SAY so — the failure mode this change has
# already produced twice is not a red build, it is a check that silently does nothing while
# every test stays green.
#
# Inputs (env):
#   BUILD_VERSION     version this release would publish (required)
#   HELPER_DIR        directory holding central-preflight.sh and list-publications.init.gradle
#   RUNNER_TEMP       scratch directory (default /tmp)
#   LISTING_TIMEOUT   seconds the Gradle listing may take (default 300)
#   DRY_RUN, GH_TOKEN passed through to central-preflight.sh
#
# Runs from the consumer's checkout, so `./gradlew` is the consumer's wrapper.
#
# Exit 0 = start the release, 1 = do not. Only central-preflight.sh may say 1.

set -uo pipefail

# Defaulted, not required: `${VAR:?}` and an unset variable under `set -u` both exit 1, and
# this script is not allowed to exit 1 for any reason but the preflight's verdict. Every one
# of these has a caller that always sets it, which is precisely what was said of the
# `BUILD_VERSION:?` that was removed from central-preflight.sh for the same reason.
HELPER_DIR="${HELPER_DIR:-}"
BUILD_VERSION="${BUILD_VERSION:-}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
LISTING_TIMEOUT="${LISTING_TIMEOUT:-300}"

if [ -z "$HELPER_DIR" ]; then
  echo "::warning title=Central preflight skipped::No helper directory was passed to the preflight step, so whether ${BUILD_VERSION:-the release version} is already on Maven Central could not be checked. Continuing."
  exit 0
fi

# The same rule as the step that calls this one: a helper that is not on disk means the check
# cannot run, which is never a reason to stop a release. Checked before the listing so a
# missing preflight is not discovered after paying for Gradle.
for required in central-preflight.sh list-publications.init.gradle; do
  if [ ! -f "$HELPER_DIR/$required" ]; then
    echo "::warning title=Central preflight skipped::$HELPER_DIR/$required is missing, so whether ${BUILD_VERSION:-the release version} is already on Maven Central could not be checked. Continuing."
    exit 0
  fi
done

coords="$RUNNER_TEMP/publication-coords.txt"
rm -f "$coords"
log="$RUNNER_TEMP/list-publications.log"

# `timeout` because this is the dominant cost in a step whose entire justification is being
# cheaper than the build it replaces: `gradlew help` pays cold daemon start, full
# configuration and any configuration-time dependency resolution. A non-zero exit already
# falls open; without a ceiling a stall does not, and a stall is the one failure that would
# make this check cost more than the build it exists to save.
#
# -Pnexus=true and the version properties are passed exactly as the real upload passes them,
# because some consumers shape their publications on those: without them this could inspect a
# different artifact set than the one that gets uploaded.
#
# Two things are pinned off, both because they would skip configuration and take the listing
# with it: configure-on-demand would leave unbuilt subprojects unevaluated, so their
# publications would silently go unchecked, and a configuration-cache HIT skips configuration
# entirely, so the hook would never run. Set as `-D` properties rather than command-line
# flags on purpose: an unknown property is ignored by older Gradle versions, while an unknown
# flag would fail the invocation on the consumers still on Gradle 7.
# timeout(1) is coreutils, present on the runners and absent on a stock macOS. Without this
# detection the listing would simply fail there — and because the failure falls open, the
# preflight would silently become a no-op with nothing red to show for it. Degrade to running
# without a ceiling and say so, rather than depending on a binary that may not be there.
declare -a bounded=()
if command -v timeout >/dev/null 2>&1; then
  bounded=(timeout "$LISTING_TIMEOUT")
else
  echo "::warning title=Coordinate listing is unbounded::timeout(1) is not available, so the listing runs without a ceiling. It can still only warn, never fail the release."
fi

if ! OCTOPUS_COORDS_FILE="$coords" OCTOPUS_RELEASE_VERSION="$BUILD_VERSION" \
     ${bounded[@]+"${bounded[@]}"} ./gradlew help -q \
       --init-script "$HELPER_DIR/list-publications.init.gradle" \
       -Dorg.gradle.configureondemand=false \
       -Dorg.gradle.configuration-cache=false \
       -Pnexus=true -PbuildVersion="$BUILD_VERSION" -Pversion="$BUILD_VERSION" \
       > "$log" 2>&1; then
  echo "::warning title=Publication listing failed::Could not list the publication coordinates (timed out, or Gradle exited non-zero — see below); the preflight will report that it could not check."
fi

if [ -s "$coords" ]; then
  echo "Publications this release would publish:"
  sed 's/^/  /' "$coords"
else
  tail -n 40 "$log" 2>/dev/null || true
fi

# A publication carrying another version is a build defect, and the listing already saw it —
# the init script skips it by name. Surfacing it here is the earliest anything can: the
# publication guard makes the same finding after the build, and the Portal makes it after the
# upload. Only a warning, because the preflight may not stop a release on anything but a
# fully published version, and because a mixed set is exactly the case that would otherwise
# be silent: the coordinate file is non-empty, so the log above is not printed.
if skipped="$(grep -F 'not the version being released' "$log" 2>/dev/null)" && [ -n "$skipped" ]; then
  echo "::warning title=Publication at another version::The publication listing skipped $(printf '%s\n' "$skipped" | grep -c .) publication(s) carrying a version other than ${BUILD_VERSION}. They are not checked against Central, and the publication guard will refuse the release after the build unless the version properties reach every project that declares a publication."
  printf '%s\n' "$skipped" | sed 's/^/  /'
fi

COORDS_FILE="$coords" bash "$HELPER_DIR/central-preflight.sh"
