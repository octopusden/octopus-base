#!/usr/bin/env bash
#
# Wait until a freshly created tag ref is READABLE, then exit 0.
#
# Why this exists as its own script rather than inline in the release workflow: it is the one
# piece of that step with a failure mode worth testing, and a 900-line reusable workflow cannot
# be invoked from a test. See .github/workflows/test-wait-for-tag-ref.yml.
#
# The problem it solves, observed on octopus-api-gateway 2.0.19: `gh api .../git/refs` created
# the tag and returned success, and the very next command — `gh release create --verify-tag` —
# reported `tag v2.0.19 doesn't exist`. The tag was there afterwards, at the built commit. That
# command performs its OWN lookup, and the read missed a ref committed milliseconds earlier.
# Losing that race leaves a half-release: artifacts already published, tag created, no release.
#
# It waits on the EXACT lookup that command performs: remoteTagExists in cli/cli
# pkg/cmd/release/create/http.go queries GraphQL `repository.ref(qualifiedName:)`. Polling the
# REST ref endpoint instead would prove nothing — the two are separate read paths, and REST can
# answer while GraphQL is still stale, which is the staleness that actually breaks the release.
#
# Usage: wait-for-tag-ref.sh <owner/repo> <tag>
# Env:   WAIT_ATTEMPTS (default 10), WAIT_INTERVAL seconds (default 2)
#
# Deliberately NOT `set -e`: the lookup is expected to fail on early attempts, and the whole
# point is to keep going. Failure is reported by exit status, once, at the end.
set -uo pipefail

repo=${1:?usage: wait-for-tag-ref.sh <owner/repo> <tag>}
tag=${2:?usage: wait-for-tag-ref.sh <owner/repo> <tag>}
attempts=${WAIT_ATTEMPTS:-10}
interval=${WAIT_INTERVAL:-2}
owner=${repo%%/*}
name=${repo##*/}

read -r -d '' query <<'GQL'
query($owner: String!, $name: String!, $tagName: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $tagName) { id }
  }
}
GQL

i=0
while [ "$i" -lt "$attempts" ]; do
    i=$((i + 1))
    # An absent tag is NOT an error here: GraphQL answers 200 with a null ref, so the exit
    # status says nothing. `// empty` makes that case print nothing, and emptiness — not the
    # status — is what decides, exactly as gh's own `Ref.ID != ""` does.
    ref_id=$(gh api graphql \
        -f query="${query}" \
        -f owner="${owner}" \
        -f name="${name}" \
        -f tagName="refs/tags/${tag}" \
        --jq '.data.repository.ref.id // empty' 2>/dev/null)
    if [ -n "${ref_id}" ]; then
        [ "$i" -gt 1 ] && echo "Tag ${tag} became readable on attempt ${i}."
        exit 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$interval"
done

echo "::error title=Tag not readable after creation::Created ${tag} but it was still not readable after ${attempts} attempts. The artifacts for this version are already published, so do NOT re-dispatch the release — that would try to publish a version that already exists. Use GitHub's 're-run failed jobs' on this run once the ref is visible: that repeats only this job, which adopts the existing tag and attaches the release." >&2
exit 1
