#!/usr/bin/env bash
# Cases for sonar-analysis-params.sh. No network, no Sonar server, no git repository — the script
# reads environment and writes $GITHUB_OUTPUT, so the whole contract is assertable here.
#
# Every fixture below is hardcoded, never `${VAR:-fixture}`. GITHUB_REPOSITORY is set by Actions,
# so a default would have applied on a laptop and not in CI — green locally, red on the runner.
#
# Run under `bash -e`, the way Actions invokes a `run:` block.
set -uo pipefail
S="$PWD/.github/scripts/sonar-analysis-params.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failures=0

# Runs the script with the given environment and echoes "key=value" lines it produced.
run_case() {
  local out="$tmp/out"; : > "$out"
  env GITHUB_OUTPUT="$out" \
      GITHUB_REPOSITORY="octopusden/octopus-widget" \
      ORGANIZATION_INPUT="${ORGANIZATION_INPUT:-}" \
      PROJECT_KEY_INPUT="${PROJECT_KEY_INPUT:-}" \
      LATEST_TAG="${LATEST_TAG:-}" \
      FALLBACK_VERSION="${FALLBACK_VERSION:-0.0.0}" \
      DEFAULT_BRANCH_INPUT="${DEFAULT_BRANCH_INPUT:-}" \
      REPO_DEFAULT_BRANCH="${REPO_DEFAULT_BRANCH:-main}" \
      EVENT_NAME="${EVENT_NAME:-push}" \
      REF_NAME="${REF_NAME:-main}" \
      bash "$S" > /dev/null
  cat "$out"
}

expect() {
  local label="$1" key="$2" want="$3" got
  got=$(grep -E "^${key}=" "$tmp/out" | head -1 | cut -d= -f2-)
  if [[ "$got" != "$want" ]]; then
    echo "FAIL  ${label}: ${key} expected '${want}', got '${got}'" >&2
    failures=$((failures + 1))
  else
    echo "ok    ${label}: ${key}=${got:-<empty>}"
  fi
}

# --- the branch decision, which is the reason this script exists ------------------------------

( EVENT_NAME=push REF_NAME=main run_case ) >/dev/null
expect "push to default branch" reference-branch ""

( EVENT_NAME=push REF_NAME=feature/abc run_case ) >/dev/null
expect "push to feature branch" reference-branch "main"

# A pull request must NOT carry a reference branch: Sonar treats the PR diff as new code, and the
# property can make the PR be analysed as a branch instead.
( EVENT_NAME=pull_request REF_NAME=feature/abc run_case ) >/dev/null
expect "pull request" reference-branch ""

# A repository whose default branch is not `main` must compare against its own default.
( EVENT_NAME=push REF_NAME=feature/abc REPO_DEFAULT_BRANCH=trunk run_case ) >/dev/null
expect "non-main default branch" reference-branch "trunk"

( EVENT_NAME=push REF_NAME=trunk REPO_DEFAULT_BRANCH=trunk run_case ) >/dev/null
expect "push to non-main default branch" reference-branch ""

# The input overrides what the event says the default branch is.
( EVENT_NAME=push REF_NAME=feature/abc DEFAULT_BRANCH_INPUT=release REPO_DEFAULT_BRANCH=main run_case ) >/dev/null
expect "default-branch input wins" reference-branch "release"

# An unset REPO_DEFAULT_BRANCH must not make every branch its own reference.
( EVENT_NAME=push REF_NAME=feature/abc REPO_DEFAULT_BRANCH= run_case ) >/dev/null
expect "empty default branch falls back to main" reference-branch "main"

# --- project key and organisation -------------------------------------------------------------

( run_case ) >/dev/null
expect "derived key" project-key "octopusden_octopus-widget"
expect "derived organisation" organization "octopusden"

( ORGANIZATION_INPUT=other PROJECT_KEY_INPUT=custom_key run_case ) >/dev/null
expect "key override" project-key "custom_key"
expect "organisation override" organization "other"

# --- version ------------------------------------------------------------------------------------

( LATEST_TAG=v2.0.8 run_case ) >/dev/null
expect "tag used verbatim" version "v2.0.8"

# No tag is the never-released repository; it must not fail the analysis.
( LATEST_TAG= FALLBACK_VERSION=0.0.0 run_case ) >/dev/null
expect "untagged repository" version "0.0.0"

echo
if [[ "$failures" -ne 0 ]]; then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "All cases passed."
