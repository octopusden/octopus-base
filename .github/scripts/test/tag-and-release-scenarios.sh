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
# and the release asset can never gate the release.
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
  (
    export CALL_LOG GITHUB_REPOSITORY=octopusden/octopus-test TAG=v2.0.15
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
base; REL_STATE=draft; export REL_STATE
run "a draft with no tag is adopted, not collided with" 0 \
  "ref-lookup repos/octopusden/octopus-test/git/ref/tags/v2.0.15 ref-create api repos/octopusden/octopus-test/git/refs -f ref=refs/tags/v2.0.15 -f sha=$SHA_BUILT --jq .ref graphql release-view draft-query publish" \
  "publishing it"

# The ref must be created AND VISIBLE before the draft is published. Publishing a draft is itself
# a tag-creating operation: GitHub materialises the tag from the draft's own target_commitish,
# which need not be the commit that was built. So the GraphQL wait has to come before `publish`,
# not only before a `release create` — the sequence below is the assertion, and it is the one path
# neither inline copy ever reached, because both died at "release already exists" first.
base; REL_STATE=draft; export REL_STATE
run "the ref is waited for before the draft is published, not only before a create" 0 \
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

echo
echo "tag-and-release scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
