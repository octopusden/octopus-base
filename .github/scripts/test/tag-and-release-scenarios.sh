#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/tag-and-release.sh — the step that runs AFTER the artifacts
# are on Maven Central and immutable, where every wrong answer is permanent.
#
# These branches could not be tested at all while this logic was two inline step bodies, which is
# the main reason it is now a script. Each case below is a state the pipeline has actually reached
# or can reach: a tag that outlived its release, a draft left by an interrupted attempt, a lookup
# that fails for a reason other than 404, a ref creation refused by the workflow-file rule (#180).
#
# The property under test throughout: nothing is created on unverified state, nothing is moved,
# and the release asset can never gate the release — while the release ARTIFACT, the file a
# release publishes when nothing goes to Central, always does.
#
# Usage: bash .github/scripts/test/tag-and-release-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
script="$scripts/tag-and-release.sh"
[ -f "$script" ] || { echo "tag-and-release.sh not found"; exit 1; }

SHA_BUILT="$(printf 'a%.0s' {1..40})"
SHA_OTHER="$(printf 'b%.0s' {1..40})"
pass=0; fail=0

# run <name> <expected-rc> <expected-call-log-or-empty> [<must-match-in-output>]
# The call log is compared as an ordered, space-joined sequence: ordering is part of the contract.
run() {
  local name="$1" erc="$2" want_calls="${3:-}" want_out="${4:-}" ok=true
  local tmp; tmp="$(mktemp -d)"
  local out="$tmp/out.txt" rc=0
  CALL_LOG="$tmp/calls.txt"; : > "$CALL_LOG"
  # What the release holds under the artifact's name when the run starts; the stub rewrites it.
  ARTIFACT_STATE_FILE="$tmp/artifact-on-release"; printf '%s' "${ARTIFACT_ON_RELEASE:-}" > "$ARTIFACT_STATE_FILE"
  (
    export CALL_LOG ARTIFACT_STATE_FILE GITHUB_REPOSITORY=octopusden/octopus-test TAG=v2.0.15
    export PATH="$here/tagrelease:$PATH"
    export GITHUB_STEP_SUMMARY="$tmp/summary.md"
    bash "$script"
  ) >"$out" 2>&1 || rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  expected rc $erc, got $rc"; }
  if [ -n "$want_calls" ]; then
    local got; got="$(tr '\n' ' ' < "$CALL_LOG" | sed 's/  */ /g; s/ $//')"
    [ "$got" = "$want_calls" ] || { ok=false; echo "  calls:    $got"; echo "  expected: $want_calls"; }
  fi
  [ -z "$want_out" ] || grep -q "$want_out" "$out" || { ok=false; echo "  output did not mention: $want_out"; }

  if $ok; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/    | /' "$out"; fi
  rm -rf "$tmp"
}

base() {
  export BUILT_SHA="$SHA_BUILT" RELEASE_ASSET=""
  export REF_STATE=absent REF_SHA="$SHA_BUILT" REF_CREATE=ok
  export REL_STATE=absent REL_ASSETS="" ASSETS_READ=ok UPLOAD=ok GRAPHQL_REF=id
  export REL_CREATE=ok REL_EDIT=ok DRAFT_QUERY=ok
  export RELEASE_ARTIFACT="" ARTIFACT_ON_RELEASE="" ARTIFACT_READ=ok DELETE_ASSET=ok
  # The wait succeeds on its first attempt whenever GRAPHQL_REF=id, so these only bound the cases
  # where it is meant to fail — without them each of those would sleep for twenty seconds.
  export WAIT_ATTEMPTS=1 WAIT_INTERVAL=0
}

# --- the ordinary paths --------------------------------------------------------------------
base
run "no tag and no release: create the ref, wait, then publish a release" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view graphql create-published" \
  "Created tag and release"

base; REL_STATE=published; REF_STATE=exists; export REL_STATE REF_STATE
run "tag and release both correct: change nothing" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15 release-view draft-query" \
  "already exists"

base; REF_STATE=exists; export REF_STATE
run "tag correct but no release: adopt the tag" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15 release-view graphql create-published" \
  "in place"

# --- the stranded draft, which the Gradle flow used to wedge on ----------------------------
# GitHub creates the tag only when a draft is published, so an interrupted attempt leaves a draft
# with NO ref. The old inline Gradle body only looked for a release on the path where the ref
# already existed, so here it created the ref and then died on "release already exists".
# The ref must be created AND VISIBLE before the draft is published. Publishing a draft is itself
# a tag-creating operation: GitHub materialises the tag from the draft's own target_commitish,
# which need not be the commit that was built. So the `graphql` wait has to come before `publish`,
# not only before a `release create` — its position in the sequence below is the assertion, and
# this is the one path neither inline copy ever reached, because both died at "release already
# exists" first.
base; REL_STATE=draft; export REL_STATE
run "a draft with no tag is adopted, and the ref is waited for before it is published" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view draft-query publish" \
  "publishing it"

base; REF_STATE=exists REL_STATE=draft; export REF_STATE REL_STATE
run "a draft on a correct existing tag is published" 0 "" "publishing it"

# --- refusals: nothing may be created or moved on unverified state -------------------------
base; REF_STATE=exists REF_SHA="$SHA_OTHER"; export REF_STATE REF_SHA
run "a tag standing at another commit is never moved" 1 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15" \
  "Release tag conflict"

base; REF_STATE=error; export REF_STATE
run "a ref lookup that fails for any reason but 404 stops everything" 1 "" "Tag lookup failed"

base; REL_STATE=error; export REL_STATE
run "a release lookup that fails for any reason but 404 stops everything" 1 "" "Release lookup failed"

base; REF_CREATE=refused; export REF_CREATE
run "a refused ref creation is reported as the workflow-file rule, not a bare 404" 1 "" "Tag creation refused"

base; unset BUILT_SHA
run "no built commit: nothing is tagged" 1 "" "Built commit unknown"

# --- the asset may never gate the release --------------------------------------------------
tmpasset="$(mktemp -d)/pom.xml"; printf '<project/>\n' > "$tmpasset"

base; RELEASE_ASSET="$tmpasset"; export RELEASE_ASSET
run "with an asset: draft, attach, then publish — in that order" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view graphql create-draft upload $tmpasset publish" \
  "Attached"

base; RELEASE_ASSET="$tmpasset" UPLOAD=error; export RELEASE_ASSET UPLOAD
run "a refused upload still leaves a published release" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view graphql create-draft upload $tmpasset publish" \
  "refused the asset upload"

base; RELEASE_ASSET="/nonexistent/pom.xml"; export RELEASE_ASSET
run "a missing asset file still leaves a published release" 0 "" "could not be restored"

base; REF_STATE=exists REL_STATE=published RELEASE_ASSET="$tmpasset" REL_ASSETS="pom.xml"
export REF_STATE REL_STATE RELEASE_ASSET REL_ASSETS
run "an asset already attached is not re-uploaded" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15 release-view assets-query draft-query" \
  "attached — nothing to do"

base; REF_STATE=exists REL_STATE=published RELEASE_ASSET="$tmpasset" REL_ASSETS="other.jar"
export REF_STATE REL_STATE RELEASE_ASSET REL_ASSETS
run "a release missing its asset gets one, without clobbering" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15 release-view assets-query upload $tmpasset draft-query" \
  "Attached"

base; REF_STATE=exists REL_STATE=published RELEASE_ASSET="$tmpasset" ASSETS_READ=error
export REF_STATE REL_STATE RELEASE_ASSET ASSETS_READ
run "an unreadable asset list tries the upload rather than failing the job" 0 "" "assets unreadable"

# --- a failed release step may never report success -----------------------------------------
# `set -e` is on, but the shell suspends it for the whole body of a function called as part of a
# `||` list — and create_or_adopt_release is always called that way, so nothing inside it or the
# functions it calls is fatal by default. Each case below fails one step in there and asserts the
# run stops and says which ledger was left short. Reverting any of those checks turns this suite
# red instead of shipping a green half-release: a run reporting "Created tag and release" with no
# release is the #189 shape itself.

base; GRAPHQL_REF=empty; export GRAPHQL_REF
run "a ref that never becomes readable stops the run before any release call" 1 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql" \
  "not readable after"

base; REF_STATE=exists GRAPHQL_REF=empty; export REF_STATE GRAPHQL_REF
run "the same wait failing while adopting an existing tag is fatal too" 1 "" \
  "Release not completed"

base; REL_CREATE=error; export REL_CREATE
run "a refused release creation is reported, not announced as created" 1 "" \
  "Release not completed"

base; REF_STATE=exists REL_STATE=draft REL_EDIT=error; export REF_STATE REL_STATE REL_EDIT
run "a draft that cannot be published fails the run" 1 "" "Draft not published"

base; REF_STATE=exists REL_STATE=published DRAFT_QUERY=error; export REF_STATE REL_STATE DRAFT_QUERY
run "an unreadable draft state is not read as 'not a draft'" 1 "" "Draft state unreadable"

# The asset path is where a refused create would otherwise be masked: `attach_asset` runs next and
# never fails, so without the check the run would carry on to publish a release that was never
# created. The non-asset path needs no such check — the create is the last command there.
base; RELEASE_ASSET="$tmpasset" REL_CREATE=error; export RELEASE_ASSET REL_CREATE
run "a refused draft creation is not masked by the asset upload that follows" 1 "" \
  "Release not completed"

base; RELEASE_ASSET="$tmpasset" REL_EDIT=error; export RELEASE_ASSET REL_EDIT
run "an asset release that cannot be published is reported as left a draft" 1 "" \
  "Release left as a draft"

# --- the artifact always gates the release --------------------------------------------------
# RELEASE_ARTIFACT is the file a release publishes when nothing goes to Central, so every rule of
# the asset section is inverted: no path may reach `publish` unless the release holds exactly this
# run's file. Each sequence below ends where the script must stop; a `publish` after a failed or
# mismatched artifact is the defect. Every scenario above runs with RELEASE_ARTIFACT unset and
# compares the whole call sequence, which is what shows the existing callers are untouched.
artifact="$(mktemp -d)/plugin-2.0.15.jar"; printf 'this build\n' > "$artifact"
ours="uploaded sha256:$(sha256sum "$artifact" | cut -d' ' -f1)"
NEW="ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view"
ADOPT="ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 commit-lookup repos/octopusden/octopus-test/commits/v2.0.15 release-view"

base; RELEASE_ARTIFACT="$artifact"; export RELEASE_ARTIFACT
run "with an artifact: draft, upload, read it back, then publish — in that order" 0 \
  "$NEW graphql create-draft artifact-query upload $artifact artifact-query publish" \
  "holds plugin-2.0.15.jar"

base; RELEASE_ARTIFACT="$artifact" UPLOAD=error; export RELEASE_ARTIFACT UPLOAD
run "a refused artifact upload leaves the draft unpublished" 1 \
  "$NEW graphql create-draft artifact-query upload $artifact" \
  "Release artifact not uploaded"

base; RELEASE_ARTIFACT="$artifact" UPLOAD=starter; export RELEASE_ARTIFACT UPLOAD
run "an upload that fails and leaves an empty asset leaves the draft unpublished" 1 \
  "$NEW graphql create-draft artifact-query upload $artifact" \
  "Release not completed"

# The re-run of the case above: the tag exists, the draft exists, and the empty asset holds the
# name. Without the delete the upload is refused on every attempt and the release never finishes.
base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft ARTIFACT_ON_RELEASE="starter"
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_ON_RELEASE
run "a re-run replaces the empty asset, then publishes" 0 \
  "$ADOPT artifact-query delete-asset plugin-2.0.15.jar upload $artifact artifact-query draft-query publish" \
  "left by a failed upload"

base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft ARTIFACT_ON_RELEASE="starter" DELETE_ASSET=error
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_ON_RELEASE DELETE_ASSET
run "an empty asset that cannot be deleted stops the run before any upload" 1 \
  "$ADOPT artifact-query delete-asset plugin-2.0.15.jar" \
  "Release artifact not replaced"

# A draft with no tag, already holding a same-named file built from another commit: the name
# matches and the content does not. It is neither replaced nor published.
base; RELEASE_ARTIFACT="$artifact" REL_STATE=draft ARTIFACT_ON_RELEASE="uploaded sha256:another-build"
export RELEASE_ARTIFACT REL_STATE ARTIFACT_ON_RELEASE
run "an adopted draft holding another build's file is refused, not replaced or published" 1 \
  "$NEW artifact-query" \
  "Release artifact mismatch"

# An asset uploaded before GitHub recorded digests has none, so it cannot be shown to be this file.
base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft ARTIFACT_ON_RELEASE="uploaded"
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_ON_RELEASE
run "a same-named file with no digest is refused" 1 "$ADOPT artifact-query" "Release artifact mismatch"

base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft ARTIFACT_ON_RELEASE="$ours"
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_ON_RELEASE
run "a draft already holding this run's file is published without another upload" 0 \
  "$ADOPT artifact-query draft-query publish" \
  "holds plugin-2.0.15.jar"

base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=published ARTIFACT_ON_RELEASE="$ours"
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_ON_RELEASE
run "a published release holding this run's file: change nothing" 0 \
  "$ADOPT artifact-query draft-query" \
  "in place"

# The asset's list lookup degrades to "try the upload"; the artifact's fails closed.
base; RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft ARTIFACT_READ=error
export RELEASE_ARTIFACT REF_STATE REL_STATE ARTIFACT_READ
run "an unreadable release stops the run instead of publishing on unknown state" 1 \
  "$ADOPT artifact-query" \
  "Release artifact unreadable"

base; RELEASE_ARTIFACT="/nonexistent/plugin-2.0.15.jar" REF_STATE=error; export RELEASE_ARTIFACT REF_STATE
run "a missing artifact file stops the run before the first lookup" 1 "" "Release artifact missing"

# gh exiting 0 is not the evidence: the release is read back, and that is what is compared.
base; RELEASE_ARTIFACT="$artifact" UPLOAD=corrupt; export RELEASE_ARTIFACT UPLOAD
run "an upload gh calls successful is not published until the read-back matches" 1 \
  "$NEW graphql create-draft artifact-query upload $artifact artifact-query" \
  "Release artifact mismatch"

# The Maven flow sets both — the only configuration a caller uses today: the pom.xml stays a
# best-effort asset, the artifact gates. The asset's own outcome must never open the gate.
base; RELEASE_ASSET="$tmpasset" RELEASE_ARTIFACT="$artifact"; export RELEASE_ASSET RELEASE_ARTIFACT
run "asset and artifact together: the asset first, then the gate, then publish" 0 \
  "$NEW graphql create-draft upload $tmpasset artifact-query upload $artifact artifact-query publish" \
  "holds plugin-2.0.15.jar"

# "Re-run failed jobs" after the artifact's upload failed: the tag and the draft exist and the
# pom.xml is already attached. The asset path reports "nothing to do"; the gate still runs.
base; RELEASE_ASSET="$tmpasset" RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft REL_ASSETS="pom.xml"
export RELEASE_ASSET RELEASE_ARTIFACT REF_STATE REL_STATE REL_ASSETS
run "asset and artifact on a re-run: the missing artifact is uploaded before the draft is published" 0 \
  "$ADOPT assets-query artifact-query upload $artifact artifact-query draft-query publish" \
  "holds plugin-2.0.15.jar"

base; RELEASE_ASSET="$tmpasset" RELEASE_ARTIFACT="$artifact" REF_STATE=exists REL_STATE=draft REL_ASSETS="pom.xml"
ARTIFACT_ON_RELEASE="uploaded sha256:another-build"
export RELEASE_ASSET RELEASE_ARTIFACT REF_STATE REL_STATE REL_ASSETS ARTIFACT_ON_RELEASE
run "asset and artifact on a re-run: another build's file is refused although the asset is fine" 1 \
  "$ADOPT assets-query artifact-query" \
  "Release artifact mismatch"

echo
echo "tag-and-release scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
