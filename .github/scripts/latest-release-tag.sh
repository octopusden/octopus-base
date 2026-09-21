#!/usr/bin/env bash
# Writes the newest release tag in the checkout to $GITHUB_OUTPUT as `latest-tag`, empty when the
# repository has never been released.
#
# Not `oprypin/find-latest-tag`: it reports an HTTP, permission or input failure the same way it
# reports "no tag exists", so the workflow cannot tell them apart. The empty answer then becomes
# `fallback-version`, which moves the Sonar baseline on a transient error and moves it back once
# the error clears. The tags are already in the checkout, so there is nothing left to fail.
#
# Inputs (environment):
#   VERSION_TAG_REGEX  extended regex selecting release tags
set -euo pipefail

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "::error title=Shallow checkout::Tags are missing, so every release would read as unreleased. Check out with fetch-depth: 0." >&2
  exit 1
fi

# -v:refname orders 10.0.1 above 9.0.0; plain refname does not. Enumeration failures propagate
# under `set -e`; only grep's own statuses are interpreted below.
tags=$(git tag --list --sort=-v:refname)

# grep exits 1 for "no match" and 2 for "bad expression", and the two must not be confused: a
# misconfigured version-tag-regex would otherwise read as an unreleased repository and submit the
# fallback version, resetting the baseline and resetting it again once the regex is corrected.
set +e
matching=$(printf '%s\n' "$tags" | grep -E "$VERSION_TAG_REGEX")
grep_status=$?
set -e

if [[ "$grep_status" -gt 1 ]]; then
  echo "::error title=Invalid tag regex::version-tag-regex '${VERSION_TAG_REGEX}' is not a valid extended regular expression." >&2
  exit 1
fi

latest=$(printf '%s\n' "$matching" | head -1)

echo "latest-tag=${latest}" >> "${GITHUB_OUTPUT}"
if [[ -n "$latest" ]]; then
  echo "Latest release tag: ${latest}"
else
  echo "No tag matches ${VERSION_TAG_REGEX}; the analysis falls back to the configured version."
fi
