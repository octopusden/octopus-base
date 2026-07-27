#!/usr/bin/env bash
# Resolves the version that a release run published, for registration in the release
# log. Prints the bare version (no leading "v") on stdout; explains its reasoning on
# stderr.
#
# Environment:
#   EXPLICIT_VERSION  version supplied by the caller; wins when set (leading "v" ok)
#   RELEASE_RUN_SHA   commit reported for the triggering release run
#   GITHUB_REPOSITORY owner/repo, used for the release lookup
#   GH_TOKEN          token for that lookup
#
# Three sources, in order of how much they can be trusted:
#
#   1. What the caller says. The release workflow knows the version it built, so when
#      it registers directly there is nothing to infer.
#   2. The version tag on the commit the release run reports. Precise when it yields
#      exactly one candidate.
#   3. The most recently created release in the repository. Needed because neither of
#      the above always holds: for a repository_dispatch run, the reported commit is
#      the default branch tip at dispatch time, while a hybrid-flow release tags the
#      commit it was told to build; and a commit can carry several version tags —
#      octopus-test has two on one commit today.
#
# What is deliberately NOT used: the highest version tag in the repository. That was
# the previous implementation, and it is wrong by construction — it answers "which tag
# sorts highest", not "what did this run release". A leftover canary tag v9.9.9 thereby
# hijacked a real 2.2.37 release: the log recorded 9.9.9, post-processing ran for
# 9.9.9, and the component's stored latest version became 9.9.9. Sorting by creation
# time instead of by version number is what makes source 3 safe against that.
set -euo pipefail

EXPLICIT_VERSION="${EXPLICIT_VERSION:-}"
RELEASE_RUN_SHA="${RELEASE_RUN_SHA:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

die() {
  echo "$*" >&2
  exit 1
}

note() {
  echo "$*" >&2
}

if [ -n "$EXPLICIT_VERSION" ]; then
  version="${EXPLICIT_VERSION#v}"
  grep -qE "$SEMVER" <<<"$version" || die "The supplied release version is not a version number: '$EXPLICIT_VERSION'."
  note "Version supplied by the caller."
  printf '%s\n' "$version"
  exit 0
fi

# Source 2: version tags on the reported commit.
candidates=()
if [ -n "$RELEASE_RUN_SHA" ]; then
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    candidates+=("${tag#v}")
  done < <(git tag --points-at "$RELEASE_RUN_SHA" 2>/dev/null \
    | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" \
    | sort -u)
fi

if [ "${#candidates[@]}" -eq 1 ]; then
  note "Resolved from the only version tag on $RELEASE_RUN_SHA."
  printf '%s\n' "${candidates[0]}"
  exit 0
fi

if [ "${#candidates[@]}" -gt 1 ]; then
  note "Commit $RELEASE_RUN_SHA carries several version tags (${candidates[*]}), so it cannot say which one this run released."
else
  note "No version tag on ${RELEASE_RUN_SHA:-<no commit reported>}; the release was probably cut from another commit."
fi

# Source 3: the most recently created release.
[ -n "$GITHUB_REPOSITORY" ] || die "Cannot look up the latest release: the repository is unknown. Pass release-version explicitly."

latest_tag="$(gh api "repos/${GITHUB_REPOSITORY}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
[ -n "$latest_tag" ] && [ "$latest_tag" != "null" ] \
  || die "Could not determine the released version: no version tag on the reported commit and the latest release could not be read. Pass release-version explicitly."

version="${latest_tag#v}"
grep -qE "$SEMVER" <<<"$version" \
  || die "The latest release is tagged '$latest_tag', which is not a plain version number, so it cannot be registered. Pass release-version explicitly."

note "Resolved from the most recently created release ($latest_tag)."
printf '%s\n' "$version"
