#!/usr/bin/env bash
# Resolves the Sonar parameters both sonar workflows need, and appends them to $GITHUB_OUTPUT.
# Extracted from the workflows so the branch decision below can be tested without a Sonar server.
#
# Inputs (environment):
#   GITHUB_REPOSITORY      owner/repo
#   ORGANIZATION_INPUT     override; empty means the GitHub owner
#   PROJECT_KEY_INPUT      override; empty means <owner>_<repo>
#   LATEST_TAG             newest release tag, empty if none
#   FALLBACK_VERSION       version to use when there is no tag
#   DEFAULT_BRANCH_INPUT   override; empty means REPO_DEFAULT_BRANCH
#   REPO_DEFAULT_BRANCH    the repository's default branch, empty means "main"
#   EVENT_NAME             github.event_name
#   REF_NAME               github.ref_name
set -euo pipefail

repo_name="${GITHUB_REPOSITORY##*/}"
owner="${GITHUB_REPOSITORY%%/*}"

organization="${ORGANIZATION_INPUT:-$owner}"
project_key="${PROJECT_KEY_INPUT:-${owner}_${repo_name}}"

# The tag is passed through untouched. A version that never changes makes new code mean every
# commit since the first analysis; one that moves per build makes an issue new code for exactly
# one analysis. Neither errors.
version="${LATEST_TAG:-$FALLBACK_VERSION}"

# New code on a non-default branch is its diff against the default branch, set here because a
# branch needs its definition before its first analysis and only CI knows the branch name.
#
# Not set on pull requests: Sonar already treats the whole PR diff as new code there, and this
# property can make a PR be analysed as a branch. Not set on the default branch either — that one
# wants "previous version", which has no scanner property.
#
# sonar.branch.name is deliberately absent: the scanner reads the branch from the CI environment.
default_branch="${DEFAULT_BRANCH_INPUT:-${REPO_DEFAULT_BRANCH:-main}}"
reference_branch=""
if [[ "$EVENT_NAME" != "pull_request" && "$REF_NAME" != "$default_branch" ]]; then
  reference_branch="$default_branch"
fi

{
  echo "organization=${organization}"
  echo "project-key=${project_key}"
  echo "version=${version}"
  echo "reference-branch=${reference_branch}"
} >> "${GITHUB_OUTPUT}"

echo "Analysing ${project_key} in ${organization} as version ${version}"
if [[ -n "$reference_branch" ]]; then
  echo "New code on ${REF_NAME} is its diff against ${reference_branch}"
fi
