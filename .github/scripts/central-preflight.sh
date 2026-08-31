#!/usr/bin/env bash
#
# Preflight: refuse to start a release whose version is ALREADY on Maven Central.
#
# Without this, a release builds, signs, stages and uploads every artifact before
# Sonatype rejects the batch at `closeSonatypeStagingRepository` with
#
#   Deployment reached an unexpected status: Failed
#     - Component with package url: 'pkg:maven/<group>/<artifact>@<version>' already exists
#
# i.e. a full build spent to learn something one HTTP request answers up front, reported
# with a message that names neither the situation nor the remedy (octopus-base#195).
#
# Inputs (env):
#   BUILD_VERSION      version this release would publish (required)
#   COORDS_FILE        file listing the publications this release would upload, one
#                      `group:artifact` per line, as produced by the coordinate listing in
#                      the release workflow, which already filters to the release version
#                      and deduplicates (required; may be absent or empty — see below)
#   DRY_RUN            "true" => never fail, report only
#   GITHUB_REPOSITORY  owner/repo, for the "is it recorded on our side" lookup (optional)
#   GH_TOKEN           token for that lookup (optional)
#   PREFLIGHT_BUDGET   seconds the whole repo1 sweep may take (default 90)
#
# Exit 0 = start the release, 1 = do not.
#
# WHY THIS IS FAIL-OPEN, unlike the taggability check in the same job. That check
# refuses a release it cannot verify, because failing early costs a build while failing
# late leaves a published, immutable, untagged version. Here the asymmetry runs the
# other way: this step only ever SAVES a build that would have failed anyway, so an
# unreachable repo1, an unlistable publication set or an unreadable tag must never
# block a release that would have succeeded. Anything inconclusive warns and proceeds,
# leaving the release exactly as it behaves today.
#
# Consequently only ONE verdict stops the release: every coordinate the upload would
# send is already on Central. That is not a heuristic — the upload sends exactly these
# coordinates, and Central refuses a coordinate that exists, so the close step provably
# cannot succeed. A PARTIAL overlap does NOT stop it: over-reporting by the listing
# (a publication shaped out of the real upload) could otherwise block a release whose
# actual coordinates are free.

set -uo pipefail

# Fail open even here. An empty version means nothing can be checked, and the release
# workflow guards it for both flows long before this point — but "the only verdict that may
# stop a release is that every coordinate is published" is worth being literally true rather
# than nearly true, so a broken invocation warns and gets out of the way.
if [ -z "${BUILD_VERSION:-}" ]; then
  echo "::warning title=Central preflight skipped::No release version was passed to the preflight, so there is nothing to ask Central about. Continuing."
  exit 0
fi
COORDS_FILE="${COORDS_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

REPO1="https://repo1.maven.org/maven2"
PREFLIGHT_BUDGET="${PREFLIGHT_BUDGET:-90}"
# HEAD, not GET: only the status code is read, so there is no reason to pull every POM body
# down — and the workflow comment and developer guide both describe this as a HEAD.
# The per-request ceiling is deliberately short. A repo1 HEAD answers in milliseconds, while
# the requests are serial: at a 60s ceiling a repository with eleven publications could hang
# for eleven minutes BEFORE the build, which would cost more than the build this check exists
# to save. PREFLIGHT_BUDGET bounds the sweep as a whole, so a partial outage cannot turn a
# cheap question into a long one.
NET=(-sS --head --connect-timeout 10 --max-time 20)

# Report the verdict and leave. In dry-run every stop degrades to a warning: a dry run
# publishes nothing, and this is the only run type in which the logic gets exercised
# outside a real release.
stop() { # <title> <message>
  if [ "$DRY_RUN" = "true" ]; then
    echo "::warning title=$1::$2 (dry run — a real release would stop here.)"
    exit 0
  fi
  echo "RELEASE_PUBLISH_CLASS=deterministic"
  echo "RELEASE_PUBLISH_RETRYABLE=false"
  echo "::error title=$1::$2"
  exit 1
}

if [ -z "$COORDS_FILE" ] || [ ! -s "$COORDS_FILE" ]; then
  echo "::warning title=Central preflight skipped::No publication at $BUILD_VERSION was listed — either the listing failed, or this build declares none at that version. Either way there is nothing to ask Central about. Continuing — a version that is already there will be rejected at the close step, as it was before this check existed."
  exit 0
fi

# The pattern is strict on purpose: these values are interpolated into a URL, so a
# coordinate carrying anything but the characters a Maven group or artifact id may hold —
# a version still attached, a path traversal, a shell metacharacter — is refused rather
# than sent. The listing is expected to be already filtered to the release version and
# deduplicated, so neither is redone here.
declare -a COORDS=()
# `|| [ -n "$line" ]` so a final line with no trailing newline is still read. The producer
# always terminates its lines, so this is insurance — but it insures in the direction that
# matters: silently dropping one FREE coordinate would turn a partial overlap into "every
# coordinate is published" and stop a release that would have run.
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  if [[ ! "$line" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
    echo "::warning title=Unusable publication coordinate::Ignoring '$line'."
    continue
  fi
  COORDS+=("$line")
done < "$COORDS_FILE"

if [ "${#COORDS[@]}" -eq 0 ]; then
  echo "::warning title=Central preflight skipped::None of the listed coordinates was usable, so there is nothing to ask Central about. Continuing."
  exit 0
fi

echo "::group::Asking Maven Central about $BUILD_VERSION (${#COORDS[@]} coordinate(s))"
declare -a PRESENT=() ABSENT=() UNKNOWN=()
sweep_start=$SECONDS
budget_spent=false
for i in "${!COORDS[@]}"; do
  ga="${COORDS[$i]}"
  # Out of budget: every coordinate left is recorded as unanswered rather than asked about.
  # That lands in the inconclusive branch below, which lets the release run — the same
  # outcome as any other unanswered question, reached without spending more time.
  if (( SECONDS - sweep_start >= PREFLIGHT_BUDGET )); then
    budget_spent=true
    echo "  skipped  ${COORDS[*]:$i} (the ${PREFLIGHT_BUDGET}s budget for this check is spent)"
    UNKNOWN+=("${COORDS[@]:$i}")
    break
  fi
  grp="${ga%%:*}"; art="${ga##*:}"
  # ${grp//.//} rather than ${grp//./\/}: a backslash-escaped replacement is stripped by
  # bash 5 but kept literally by bash 3.2, which would build .../org\/octopusden/... and
  # 404 every coordinate. This form means the same thing to every bash.
  url="$REPO1/${grp//.//}/$art/$BUILD_VERSION/$art-$BUILD_VERSION.pom"
  code=$(curl "${NET[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  case "$code" in
    200) echo "  PRESENT  $ga"; PRESENT+=("$ga") ;;
    404) echo "  free     $ga"; ABSENT+=("$ga") ;;
    # Anything else answers nothing: a 5xx, a rate limit, a proxy error or an empty
    # body from a dropped connection all look alike here, and none of them is
    # evidence that the version is free.
    *)   echo "  unknown  $ga (HTTP ${code:-none})"; UNKNOWN+=("$ga") ;;
  esac
done
echo "::endgroup::"

if [ "${#UNKNOWN[@]}" -gt 0 ]; then
  reason="did not answer"
  [ "$budget_spent" = true ] && reason="did not answer within this check's ${PREFLIGHT_BUDGET}s budget"
  echo "::warning title=Central preflight inconclusive::Maven Central ${reason} for ${#UNKNOWN[@]} of ${#COORDS[@]} coordinate(s) (${UNKNOWN[*]}), so whether $BUILD_VERSION is already published is unknown. Continuing rather than blocking a release that may be perfectly valid."
  exit 0
fi

if [ "${#PRESENT[@]}" -eq 0 ]; then
  echo "Maven Central holds none of the ${#COORDS[@]} coordinate(s) at $BUILD_VERSION — the version is free."
  exit 0
fi

if [ "${#ABSENT[@]}" -gt 0 ]; then
  # Neither a clean re-release nor a normal one. Report and proceed: the coordinates the
  # upload will actually send may all be free, and this step must not be the reason a
  # workable release does not run. If a sent coordinate is among the present ones, the
  # close step fails exactly as it did before this check existed.
  echo "::warning title=Version partially on Maven Central::${#PRESENT[@]} of ${#COORDS[@]} coordinate(s) at $BUILD_VERSION are already published (${PRESENT[*]}), the rest are free (${ABSENT[*]}). Central versions are immutable, so the published ones cannot be replaced. Continuing, because a partial overlap does not prove this release cannot publish — but if it fails at the close step with 'already exists', this is why. A version published without a tag or release-log entry is octopus-base#189."
  exit 0
fi

# Every coordinate is on Central: the upload cannot succeed. Which situation this is
# depends on whether OUR side recorded that release — and that distinction is the whole
# difference between "release the next version" and "run the recovery" (#195 vs #189).
tag="v$BUILD_VERSION"
recorded="unknown"
if [ -n "$GITHUB_REPOSITORY" ] && command -v gh >/dev/null 2>&1; then
  # Fail-closed reading, fail-open effect: only a confirmed 404 counts as "absent", and
  # anything else leaves `recorded` at unknown, which only softens the wording.
  ref_rc=0; ref_out="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${tag}" 2>&1)" || ref_rc=$?
  rel_rc=0; rel_out="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${tag}" 2>&1)" || rel_rc=$?
  is404() { grep -qE 'HTTP 404|"status": ?"404"|Not Found' <<<"$1"; }
  if [ "$ref_rc" -eq 0 ] && [ "$rel_rc" -eq 0 ]; then
    recorded="yes"
  elif { [ "$ref_rc" -eq 0 ] || is404 "$ref_out"; } && { [ "$rel_rc" -eq 0 ] || is404 "$rel_out"; }; then
    # At least one is a confirmed absence, and neither lookup failed for another reason.
    recorded="no"
    [ "$ref_rc" -eq 0 ] && echo "Tag ${tag} exists; the GitHub release does not."
    [ "$rel_rc" -eq 0 ] && echo "GitHub release ${tag} exists; the tag does not."
  else
    printf '%s\n%s\n' "$ref_out" "$rel_out" >&2
    echo "::warning title=Recorded-state lookup failed::Could not determine whether ${tag} is recorded on our side; reporting the Central finding alone."
  fi
fi

case "$recorded" in
  yes)
    stop "Version already released" \
      "$BUILD_VERSION is already published on Maven Central (all ${#PRESENT[@]} coordinate(s)) and already recorded here: tag ${tag} and its GitHub release exist. Nothing to do — this release would rebuild the same version and be rejected at the close step. Release the next version instead. If the dispatch came from internal CI, the version it resolved is stale: the compile build that produces the next version had not finished when the release was triggered."
    ;;
  no)
    stop "Version published but not recorded" \
      "$BUILD_VERSION is already published on Maven Central (all ${#PRESENT[@]} coordinate(s)), but ${tag} is not fully recorded here. This is octopus-base#189: an earlier run published and then died before tagging, so re-dispatching cannot work — Central refuses a version that exists. Recovery: create ${tag} on the commit that earlier run BUILT (its log reports it; the current head is usually NOT it), create the GitHub release, and register the release in octopus-release-log. Then release the next version."
    ;;
  *)
    stop "Version already on Maven Central" \
      "$BUILD_VERSION is already published on Maven Central (all ${#PRESENT[@]} coordinate(s)), so this release would be rejected at the close step after a full build. Whether it is recorded here could not be determined — check whether tag ${tag}, its GitHub release and the octopus-release-log entry exist: all present means simply release the next version, any missing means octopus-base#189 and a recovery is needed."
    ;;
esac
