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
#      Its lookup must succeed: see the fail-closed note at the call site for why a failed
#      one cannot be treated as "unstamped".
#   3. The single version tag on the commit the run reports. Correct only when that commit
#      carries exactly one version tag. RELEASE_RUN_SHA is the run's REPORTED commit — for
#      a repository_dispatch run, the default-branch head at dispatch time — while the
#      release workflow tags the commit it actually BUILT, so for a hybrid release of
#      anything else the two differ by design. That is sound rather than lucky: source 3
#      is only reached once source 2 has looked and found nothing, which means the release
#      predates stamping — and releases from that era were tagged on the reported commit,
#      which is exactly what this source reads.
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
  # Fail closed. An unreadable release list is NOT the same as "no release carries this
  # stamp", and conflating them is how a transient blip turns into a wrongly registered
  # version: the run falls through to source 3, finds the one tag an EARLIER release left
  # on the commit this run reports, and registers that version with every job green.
  # Every page, not just the first: three consumer repositories already hold more than 50
  # releases (95, 59 and 54 at the time of writing), so a single page can miss a stamp that
  # exists and then be mistaken for "this release predates stamping" — the same silent
  # wrong-version outcome the fail-closed handling below exists to prevent.
  #
  # gh applies --jq per page (without --slurp each page is filtered separately), and this
  # filter yields `empty` for a page with no match, so measured output is exactly one line
  # or nothing at all — NOT a blank line per page. The loop below still takes the first
  # non-empty line rather than the first line, so it holds if that ever changes.
  stamp_lookup=0
  stamped_pages="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    --jq "map(select((.body // \"\") | contains(\"${marker}\"))) | first | .tag_name // empty" 2>&1)" || stamp_lookup=$?
  if [ "$stamp_lookup" -ne 0 ]; then
    printf '%s\n' "$stamped_pages" >&2
    die "Could not read this repository's releases, so the release stamped by run ${RELEASE_RUN_ID}/${RELEASE_RUN_ATTEMPT} cannot be identified. Refusing to fall back to tag topology, which can name a version an earlier run released. Re-run when the API is reachable, or pass release-version explicitly."
  fi
  stamped=""
  while IFS= read -r page_result; do
    if [ -n "$page_result" ]; then
      stamped="$page_result"
      break
    fi
  done <<<"$stamped_pages"
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
