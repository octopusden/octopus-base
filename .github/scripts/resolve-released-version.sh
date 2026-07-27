#!/usr/bin/env bash
# Resolves the version that a release run actually published, for registration in
# the release log. Prints the bare version (no leading "v") on stdout.
#
# Environment:
#   EXPLICIT_VERSION  version supplied by the caller; wins when set (leading "v" ok)
#   RELEASE_RUN_SHA   the commit the triggering release run built
#
# Why not "the highest version tag in the repository", which this replaces: that
# picks whichever tag sorts highest, related to this release or not. It happened —
# a leftover canary tag v9.9.9 outranked a real 2.2.37 release, so the release log
# recorded 9.9.9, and the downstream post-processing then set the component's
# "latest released version" to 9.9.9 as well. The release run tags the commit it
# built, so the version tag on that commit is the one thing that cannot belong to
# another release.
set -euo pipefail

EXPLICIT_VERSION="${EXPLICIT_VERSION:-}"
RELEASE_RUN_SHA="${RELEASE_RUN_SHA:-}"

die() {
  echo "$*" >&2
  exit 1
}

if [ -n "$EXPLICIT_VERSION" ]; then
  printf '%s\n' "${EXPLICIT_VERSION#v}"
  exit 0
fi

[ -n "$RELEASE_RUN_SHA" ] || die \
  "Neither a release version nor a release commit was given, so the published version cannot be determined. Pass release-version explicitly."

candidates=()
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  candidates+=("${tag#v}")
done < <(git tag --points-at "$RELEASE_RUN_SHA" 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u)

case "${#candidates[@]}" in
  0)
    die "No vX.Y.Z tag points at $RELEASE_RUN_SHA. That run published no release, so there is nothing to register — refusing to guess from other tags in the repository."
    ;;
  1)
    printf '%s\n' "${candidates[0]}"
    ;;
  *)
    die "Several version tags point at $RELEASE_RUN_SHA: ${candidates[*]}. Pass release-version explicitly to say which one to register."
    ;;
esac
