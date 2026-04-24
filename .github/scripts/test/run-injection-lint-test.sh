#!/usr/bin/env bash
# run-injection-lint-test.sh — Self-contained regression test for validate-workflow-injection.sh.
#
# Test 1: lint against the PR #99 fixture → must exit 1 and mention the unsafe line.
# Test 2: lint against the real .github/workflows/ tree → must exit 0 (tree is clean).
#
# Usage: bash .github/scripts/test/run-injection-lint-test.sh [repo-dir]
# Exit 0 on all tests passing, exit 1 on any failure.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${1:-$(cd "$script_dir/../../.." && pwd)}"

lint_script="$repo_dir/.github/scripts/validate-workflow-injection.sh"
fixture_file="$repo_dir/.github/scripts/test/workflow-injection-fixture.yml"

if [[ ! -f "$lint_script" ]]; then
  echo "ERROR: lint script not found at $lint_script"
  exit 1
fi

if [[ ! -f "$fixture_file" ]]; then
  echo "ERROR: fixture file not found at $fixture_file"
  exit 1
fi

pass=0
fail=0

run_test() {
  local description="$1"
  local expected_exit="$2"
  local expected_pattern="$3"
  shift 3
  local actual_output
  local actual_exit=0

  actual_output=$("$@" 2>&1) || actual_exit=$?

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "FAIL [$description]: expected exit $expected_exit, got $actual_exit"
    echo "     Output: $actual_output"
    fail=$((fail + 1))
    return
  fi

  if [[ -n "$expected_pattern" ]] && ! echo "$actual_output" | grep -qE "$expected_pattern"; then
    echo "FAIL [$description]: output did not match pattern: $expected_pattern"
    echo "     Output: $actual_output"
    fail=$((fail + 1))
    return
  fi

  echo "PASS [$description]"
  pass=$((pass + 1))
}

# ---------------------------------------------------------------------------
# Test 1: fixture must be flagged (exit 1, mentions the unsafe expression).
# ---------------------------------------------------------------------------
# We need to point the lint at a directory that ONLY contains the fixture file.
# Create a temporary directory with just the .github/workflows/ structure.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/.github/workflows"
cp "$fixture_file" "$tmp_dir/.github/workflows/workflow-injection-fixture.yml"

# Isolate the fixture from repo-level whitelist entries: write an empty whitelist
# so every violation in the fixture must be flagged on its own merit.
mkdir -p "$tmp_dir/.github/scripts"
: > "$tmp_dir/.github/scripts/workflow-injection-whitelist.txt"

run_test \
  "fixture is flagged (PR #99 regression)" \
  1 \
  'FAIL \[injection\]' \
  bash "$lint_script" "$tmp_dir"

# Test 1b: ensure every variant is flagged.
# Count FAIL lines — fixture has 10 unsafe steps covering:
#   - "- name:" step form with run: |, |-, |+, >-, >+, inline (6 cases)
#   - "- run:" list-marker step form with inline, |, >- (3 cases)
#   - "run: | # trailing comment" — block scalar with inline YAML comment (1 case)
fixture_output="$(bash "$lint_script" "$tmp_dir" 2>&1 || true)"
fixture_fail_count=$(echo "$fixture_output" | grep -cE '^FAIL \[injection\]' || true)
if [[ "$fixture_fail_count" -lt 10 ]]; then
  echo "FAIL [fixture variant coverage]: expected ≥10 flagged lines, got $fixture_fail_count"
  echo "     Output:"
  echo "$fixture_output" | sed 's/^/       /'
  fail=$((fail + 1))
else
  echo "PASS [fixture variant coverage]: $fixture_fail_count flagged lines"
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------------
# Test 2: real workflows tree must be clean (exit 0).
# ---------------------------------------------------------------------------
run_test \
  "real workflows tree is clean" \
  0 \
  "All workflow files pass injection safety check" \
  bash "$lint_script" "$repo_dir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed."
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
