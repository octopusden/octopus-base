#!/usr/bin/env bash
# Resolves the version that a release run published, for registration in the release
# log. Prints the bare version (no leading "v") on stdout; explains its reasoning on
# stderr.
#
# Environment:
#   EXPLICIT_VERSION  version supplied by the caller; wins when set (leading "v" ok)
#   RELEASE_RUN_ID    id of the triggering release run
#   RELEASE_RUN_ATTEMPT attempt number of that run
#   RELEASE_RUN_SHA   commit reported for the triggering release run
#   GITHUB_REPOSITORY owner/repo, used for the release lookups
#   GH_TOKEN          token for those lookups
#
# Four sources, in order of how tightly each is bound to the run being registered:
#
#   1. What the caller says. The release workflow knows the version it built, so when
#      it registers directly there is nothing to infer.
#   2. The release stamped with the triggering run's id and attempt. The release
#      workflow writes that marker into the release body precisely so this step exists:
#      it is the only identity that cannot drift. The attempt matters because a rerun
#      keeps the run id while the public flow recomputes the version, so id alone would
#      match two different releases.
#   3. The single version tag on the commit the run reports. Correct only when that
#      commit carries exactly one version tag.
#   4. The most recently created release. Last resort, for a release made before the
#      stamp existed.
#
# Why 3 and 4 are not enough on their own — both can name a version another run
# released: a commit accumulates a tag per release cut from it (octopus-test has three
# such pairs in its last ten releases), and "the newest release" can advance while this
# job sits in the queue. They stay as fallbacks so releases published by an earlier
# version of the release workflow can still be registered, and each says in the log
# which source answered.
#
# What is deliberately NOT used: the highest version tag in the repository. That was
# the previous implementation, and it is wrong by construction — it answers "which tag
# sorts highest", not "what did this run release". A leftover canary tag v9.9.9 thereby
# hijacked a real 2.2.37 release: the log recorded 9.9.9, post-processing ran for
# 9.9.9, and the component's stored latest version became 9.9.9.
set -euo pipefail

EXPLICIT_VERSION="${EXPLICIT_VERSION:-}"
RELEASE_RUN_ID="${RELEASE_RUN_ID:-}"
RELEASE_RUN_ATTEMPT="${RELEASE_RUN_ATTEMPT:-}"
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

# Source 2: the release this very run stamped.
if [ -n "$RELEASE_RUN_ID" ] && [ -z "$RELEASE_RUN_ATTEMPT" ]; then
  note "Run ${RELEASE_RUN_ID} was given without an attempt number, so its stamp cannot be addressed; falling back."
fi
if [ -n "$RELEASE_RUN_ID" ] && [ -n "$RELEASE_RUN_ATTEMPT" ] && [ -n "$GITHUB_REPOSITORY" ]; then
  # Delimited so one run's marker cannot be a prefix of another's (555/1 vs 555/10).
  marker="<!-- octopus-release-run: ${RELEASE_RUN_ID}/${RELEASE_RUN_ATTEMPT} -->"
  stamped="$(gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=50" \
    --jq "map(select((.body // \"\") | contains(\"${marker}\"))) | first | .tag_name // empty" 2>/dev/null || true)"
  if [ -n "$stamped" ] && [ "$stamped" != "null" ]; then
    version="${stamped#v}"
    if grep -qE "$SEMVER" <<<"$version"; then
      note "Resolved from the release stamped with run ${RELEASE_RUN_ID}, attempt ${RELEASE_RUN_ATTEMPT}."
      printf '%s\n' "$version"
      exit 0
    fi
    note "The release stamped with run ${RELEASE_RUN_ID}/${RELEASE_RUN_ATTEMPT} is tagged '$stamped', which is not a version number."
  else
    note "No release carries this run's stamp; it predates the stamping step, so falling back."
  fi
fi

# Source 3: version tags on the reported commit.
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

# Source 4: the most recently created release.
[ -n "$GITHUB_REPOSITORY" ] || die "Cannot look up the latest release: the repository is unknown. Pass release-version explicitly."

latest_tag="$(gh api "repos/${GITHUB_REPOSITORY}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
[ -n "$latest_tag" ] && [ "$latest_tag" != "null" ] \
  || die "Could not determine the released version: no version tag on the reported commit and the latest release could not be read. Pass release-version explicitly."

version="${latest_tag#v}"
grep -qE "$SEMVER" <<<"$version" \
  || die "The latest release is tagged '$latest_tag', which is not a plain version number, so it cannot be registered. Pass release-version explicitly."

note "Resolved from the most recently created release ($latest_tag)."
printf '%s\n' "$version"
