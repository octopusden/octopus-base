#!/usr/bin/env bash
# Cases for latest-release-tag.sh, against real throwaway git repositories: the ordering it
# depends on is git's, not the script's, so a fixture that fakes `git tag` would assert nothing.
set -uo pipefail
S="$PWD/.github/scripts/latest-release-tag.sh"
REGEX='^v([0-9]+)\..*'

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failures=0

# Builds a repository carrying the given tags, runs the script in it, echoes the tag it resolved.
run_case() {
  local dir="$tmp/repo"; rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir"
    git init -q .
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    for t in "$@"; do git tag "$t"; done )
  : > "$tmp/out"
  ( cd "$dir" && env GITHUB_OUTPUT="$tmp/out" VERSION_TAG_REGEX="${REGEX_OVERRIDE:-$REGEX}" bash "$S" ) > /dev/null
}

expect() {
  local label="$1" want="$2" got
  got=$(grep -E "^latest-tag=" "$tmp/out" | head -1 | cut -d= -f2-)
  if [[ "$got" != "$want" ]]; then
    echo "FAIL  ${label}: expected '${want}', got '${got}'" >&2
    failures=$((failures + 1))
  else
    echo "ok    ${label}: ${got:-<empty>}"
  fi
}

run_case v1.0.0 v2.0.8 v1.9.0
expect "newest of several" "v2.0.8"

# Lexical ordering puts v9 above v10; the baseline would then walk backwards on release.
run_case v9.0.0 v10.0.1
expect "double-digit major" "v10.0.1"

# A repository that has never been released must fall through to the fallback, not fail.
run_case
expect "no tags at all" ""

# Tags that are not releases must not be mistaken for one.
run_case sprint-42 build_7
expect "no release tags" ""

run_case v1.0.0 sprint-42
expect "release tag among others" "v1.0.0"

# An unusable version-tag-regex is a configuration error, not an unreleased repository. grep says
# so with exit 2, and conflating that with exit 1 would submit the fallback version and move the
# baseline — twice, once when the regex breaks and once when it is fixed.
: > "$tmp/out"
if ( cd "$tmp/repo" && env GITHUB_OUTPUT="$tmp/out" VERSION_TAG_REGEX='[' bash "$S" ) > /dev/null 2>&1; then
  echo "FAIL  invalid regex: expected a failure, got success" >&2
  failures=$((failures + 1))
elif grep -q "^latest-tag=" "$tmp/out"; then
  echo "FAIL  invalid regex: wrote a tag output despite failing" >&2
  failures=$((failures + 1))
else
  echo "ok    invalid regex: rejected, nothing written"
fi

# A shallow checkout has no tags, so every released repository would read as unreleased. That must
# fail rather than quietly resolve to the fallback version.
( cd "$tmp" && rm -rf origin shallow && mkdir origin && cd origin \
    && git init -q . \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git tag v1.0.0 ) > /dev/null 2>&1
git clone -q --depth 1 "file://$tmp/origin" "$tmp/shallow" > /dev/null 2>&1
if ( cd "$tmp/shallow" && env GITHUB_OUTPUT="$tmp/out" VERSION_TAG_REGEX="$REGEX" bash "$S" ) > /dev/null 2>&1; then
  echo "FAIL  shallow checkout: expected a failure, got success" >&2
  failures=$((failures + 1))
else
  echo "ok    shallow checkout: rejected"
fi

echo
if [[ "$failures" -ne 0 ]]; then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "All cases passed."
