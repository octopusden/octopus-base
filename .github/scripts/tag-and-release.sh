#!/usr/bin/env bash
#
# Create the tag and the GitHub Release for a version that has just been published, or adopt
# whatever part of that already exists.
#
# One copy, called by the Gradle release flow, the Maven release flow, and the #189 recovery.
# It used to be an inline step body in each workflow, and the two copies had already diverged:
# the Maven one grew the release-asset handling and a stranded-draft path the Gradle one did not
# have. Two copies of the most delicate ninety lines in this repository will diverge again on the
# next fix, and the copy that matters is the one that only runs during an incident, where nobody
# is watching for a regression.
#
# Inputs (env):
#   GITHUB_REPOSITORY  owner/repo to act on (required)
#   TAG                the tag to create or adopt, e.g. v2.8.0 (required)
#   BUILT_SHA          the commit that was actually built and published (required)
#   RELEASE_ASSET      optional path to one file to attach to the release. When set, the
#                      release is created as a draft, the asset is attached, and the release is
#                      then published — see attach_asset for why that order is not optional.
#                      When empty the release is created published, with no draft phase and so
#                      no draft to strand.
#   GH_TOKEN, GH_REPO  as the callers set them; `gh release` resolves the repository from the
#                      git remote and GH_REPO is the only documented override, which matters
#                      because the tagging job has no checkout.
#
# Exit 0 = the tag and the release are in place. Any non-zero exit leaves the publish untouched:
# by the time this runs the artifacts are on Central and immutable, so every lookup here fails
# CLOSED. `gh` exits non-zero for a missing object and for an auth failure, a rate limit or a
# 5xx alike, and reading the latter as "absent" is how a release ends up pointing at stale code.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${TAG:?TAG is required}"
BUILT_SHA="${BUILT_SHA:-}"
RELEASE_ASSET="${RELEASE_ASSET:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

built_sha="${BUILT_SHA}"
if [ -z "$built_sha" ]; then
  echo "::error title=Built commit unknown::The build job did not report the commit it built, so there is nothing safe to tag." >&2
  exit 1
fi

is_404() { grep -qE 'release not found|HTTP 404|"status": ?"404"' <<<"$1"; }

# Wait for the ref to become readable before creating the release. A ref that was just created
# exists — but `gh release create --verify-tag` performs its OWN lookup, and that read can miss a
# ref committed milliseconds earlier. Observed on octopus-api-gateway 2.0.19: the ref was created
# at the built commit, the very next command reported "tag v2.0.19 doesn't exist", and the tag was
# there afterwards. Cost of losing that race is a half-release — artifacts published, tag created,
# no release and no registration — recoverable only by re-running.
#
# `--verify-tag` is deliberately KEPT rather than dropped as redundant: without it, `gh release
# create` on a tag it cannot see would create the tag ITSELF at the default branch head, which is
# the stale-code release this whole script exists to prevent. So the fix is to make the read
# succeed, not to stop checking.
#
# A separate script so the retry is testable; see .github/workflows/test-wait-for-tag-ref.yml. It
# polls the GraphQL ref query that --verify-tag itself uses, NOT a REST ref endpoint: the two are
# separate read paths and REST can answer while GraphQL is still stale. Called on EVERY path that
# creates a release, including the one that adopts a pre-existing tag — REST answering does not
# mean the GraphQL query will.
wait_for_tag() {
  bash "$here/wait-for-tag-ref.sh" "${GITHUB_REPOSITORY}" "${TAG}"
}

note_missing_asset() {
  echo "::warning title=Release asset missing::$1 The tag, the release and its run stamp are unaffected; only the attached file is missing."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Release ${TAG}: asset missing"
      echo ""
      echo "$1"
      echo "The tag, the release and the run stamp are correct; only the attached file is absent."
      echo "Attach it manually, or re-run this job while the artifact is still retained."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# The asset must never gate the release. It once could, twice over: the upload ran bare under
# `set -e`, so a 5xx from the asset endpoint aborted the step after an irreversible publish and
# before the stamp step, which skips registration; and passing files to `gh release create` makes
# it create a draft, upload, then publish inside one command, so a runner killed mid-upload left a
# draft that `releases/tags/...` does not return, blocking the stamp on every re-run.
#
# So this cannot fail, ever, and publication happens unconditionally afterwards.
attach_asset() {
  if [ ! -f "$RELEASE_ASSET" ]; then
    note_missing_asset "$(printf '%s could not be restored from the build job'\''s artifact.' "$RELEASE_ASSET")"
    return 0
  fi
  if gh release upload "$TAG" "$RELEASE_ASSET"; then
    echo "Attached $RELEASE_ASSET to ${TAG}."
    return 0
  fi
  note_missing_asset "$RELEASE_ASSET was restored but GitHub refused the asset upload."
  return 0
}

# A draft left behind by an interrupted attempt is invisible to the stamp step's
# `releases/tags/...` lookup, so publish it rather than treating it as done.
publish_if_draft() {
  if [ "$(gh release view "$TAG" --json isDraft --jq '.isDraft')" = "true" ]; then
    echo "Release ${TAG} exists as a draft — publishing it."
    gh release edit "$TAG" --draft=false
  fi
}

# A release that already exists is reconciled, not replaced.
reconcile_existing_release() {
  if [ -n "$RELEASE_ASSET" ]; then
    # An attempt interrupted between release creation and asset upload leaves the release without
    # the file, and this path would otherwise report success with the asset missing forever.
    # Upload only when it is actually absent: --clobber deletes before uploading, so a flaky
    # upload here would destroy a good asset.
    #
    # This lookup is part of the best-effort asset path, so it must not abort either: failing here
    # would skip stamping and registration over a convenience file. When the asset list cannot be
    # read, just try the upload — attach_asset never fails, and an upload of an asset that already
    # exists is refused harmlessly rather than clobbering the good one.
    local assets_lookup=0 existing_assets
    existing_assets="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>&1)" || assets_lookup=$?
    if [ "$assets_lookup" -ne 0 ]; then
      printf '%s\n' "$existing_assets" >&2
      echo "::warning title=Release assets unreadable::Could not list the assets already on ${TAG}, so the upload is attempted without knowing. The tag, the release and its run stamp are unaffected."
      attach_asset
    elif grep -qxF "$(basename "$RELEASE_ASSET")" <<<"$existing_assets"; then
      echo "Release $TAG already exists at $built_sha with $(basename "$RELEASE_ASSET") attached — nothing to do."
    else
      attach_asset
    fi
  else
    echo "Release $TAG already exists at $built_sha."
  fi
  # After the asset, never before: publishing first would put the release beyond reach of an
  # asset once immutable releases are enabled on the repository, permanently.
  publish_if_draft
}

# Look BEFORE creating, on every path. A release can exist while its tag ref does not: GitHub
# creates the tag only when a draft is published, so an attempt interrupted before that leaves a
# draft with no ref. Reaching `gh release create` in that state fails with "release already
# exists" — which is how the Gradle flow used to wedge, because it only checked for a release on
# the path where the ref already existed. The Maven flow handled it; now there is one answer.
create_or_adopt_release() {
  local rel_lookup=0 rel_out
  rel_out="$(gh release view "$TAG" 2>&1)" || rel_lookup=$?
  if [ "$rel_lookup" -eq 0 ]; then
    reconcile_existing_release
    return 0
  fi
  # Fail closed: gh exits non-zero for a missing release and for a rate limit, auth error or 5xx
  # alike, and reading the latter as "no release" makes the next line fail with a misleading
  # "release already exists".
  if ! is_404 "$rel_out"; then
    printf '%s\n' "$rel_out" >&2
    echo "::error title=Release lookup failed::Could not determine whether release ${TAG} exists. Refusing to act on unverified state; re-run when the API is reachable." >&2
    exit 1
  fi
  wait_for_tag
  if [ -n "$RELEASE_ASSET" ]; then
    # Draft, then asset, then publish. GitHub's immutable releases refuse an asset added after
    # publication, so attaching afterwards would silently stop working the day immutability is
    # enabled on a consumer repository. Publication happens unconditionally, so a refused upload
    # cannot strand the draft — and a runner killed mid-sequence leaves one that the reconcile
    # path above publishes on the next attempt. This is why `gh release create` is not given the
    # file directly: that makes it draft, upload and publish as one step, where an interrupted
    # upload leaves a draft nothing ever finishes.
    gh release create "$TAG" --verify-tag --draft --title "$TAG" --generate-notes
    attach_asset
    gh release edit "$TAG" --draft=false
  else
    gh release create "$TAG" --verify-tag --title "$TAG" --generate-notes
  fi
}

# The TAG is the authority, not the release: `gh release create --target` is IGNORED when the tag
# already exists (REST: target_commitish is "unused if the Git tag already exists"). A tag that
# outlived its release — deleting a release leaves the tag behind unless it is removed separately
# — would otherwise silently re-point a new release at stale code, which is the very bug this
# script exists to prevent. Ask the API rather than the local clone: the checkout is shallow and
# never fetches other tags.
ref_lookup=0
ref_out="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${TAG}" 2>&1)" || ref_lookup=$?

if [ "$ref_lookup" -eq 0 ]; then
  # Resolve through /commits so an annotated tag yields its commit, not the tag object.
  tag_sha="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${TAG}" --jq '.sha')"
  if [[ "$tag_sha" != "$built_sha" ]]; then
    echo "::error title=Release tag conflict::Tag ${TAG} already exists at ${tag_sha}, but this run built ${built_sha}. Not moving it. Delete the tag and its release (release immutability may prevent this once published), or release a new version." >&2
    exit 1
  fi
  create_or_adopt_release
  echo "Tag and release $TAG are in place at $built_sha"
  exit 0
fi

if ! is_404 "$ref_out"; then
  printf '%s\n' "$ref_out" >&2
  echo "::error title=Tag lookup failed::Could not determine whether ${TAG} exists (the lookup failed with something other than 404). Refusing to create a release on unverified state; re-run when the API is reachable." >&2
  exit 1
fi

# The tag is ours to create. The ref is created directly rather than through `release create
# --target` because --target is ignored once a tag exists (see above), and because creating the
# ref makes the ONE operation that can be refused explicit and separately reportable. It carries
# no lesser restriction than the release endpoint: the workflow-file rule measured in the
# pre-build check applies to any ref update, this one included.
#
# The ref is created BEFORE any draft is published, and the order matters: publishing a draft
# whose tag does not exist makes GitHub create that tag at the draft's own target_commitish,
# which is not necessarily the commit that was built. Creating the ref first makes the tag
# authoritative, and the draft then adopts it.
#
# The pre-build check said this commit was taggable, but branches move: a workflow change merged
# while the build ran can withdraw that, and by now the artifacts are published and immutable.
# Say so explicitly rather than leaving a bare masked 404 in the log.
ref_create=0
ref_create_out="$(gh api "repos/${GITHUB_REPOSITORY}/git/refs" \
  -f ref="refs/tags/${TAG}" -f sha="${built_sha}" --jq '.ref' 2>&1)" || ref_create=$?
if [ "$ref_create" -ne 0 ]; then
  printf '%s\n' "$ref_create_out" >&2
  echo "::error title=Tag creation refused::Could not create ${TAG} at ${built_sha}. An HTTP 404 here means GitHub refused the ref update because the commit carries a workflow file that now matches no branch head — the pre-build check passed, so a branch moved while this release was building. The artifacts for this version are already published and cannot be published again, so do NOT re-dispatch the release. Recovery: create ${TAG} manually on ${built_sha} with a credential authorized to modify workflows, then use GitHub's 're-run failed jobs' on this run — that repeats only this job, which will adopt the tag and attach the release, and leaves the publish untouched." >&2
  exit 1
fi

# Wait here, before ANY release operation, not only before `gh release create`. Publishing a draft
# also creates a tag: GitHub materialises it from the draft's own target_commitish, so publishing
# one while this ref is not yet visible produces a release on whatever that commitish points at —
# the stale-code release this whole file exists to prevent. The path that reaches it — ref created
# here, a draft already present with no ref of its own — is new; both inline copies died earlier,
# at `gh release create` reporting "release already exists".
wait_for_tag
create_or_adopt_release
echo "Created tag and release $TAG at $built_sha"
