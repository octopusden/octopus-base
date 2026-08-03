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

i=0
while [ "$i" -lt "$attempts" ]; do
    i=$((i + 1))
    if gh api "repos/${repo}/git/ref/tags/${tag}" >/dev/null 2>&1; then
        [ "$i" -gt 1 ] && echo "Tag ${tag} became readable on attempt ${i}."
        exit 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$interval"
done

echo "::error title=Tag not readable after creation::Created ${tag} but it was still not readable after ${attempts} attempts. The artifacts for this version are already published, so do NOT re-dispatch the release — that would try to publish a version that already exists. Use GitHub's 're-run failed jobs' on this run once the ref is visible: that repeats only this job, which adopts the existing tag and attaches the release." >&2
exit 1
