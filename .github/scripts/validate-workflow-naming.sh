#!/usr/bin/env bash
# validate-workflow-naming.sh — Lint public reusable workflow naming convention.
#
# Rules enforced:
#   1. Every common-*.yml in .github/workflows/ MUST contain a workflow_call trigger.
#   2. Every common-*.yml MUST NOT reference .github/actions/internal/ paths.
#   3. Every common-*.yml MUST NOT call a non-common local workflow via uses: ./.github/workflows/<non-common>.yml.
#   4. (Advisory) Non-common-*.yml workflows that expose workflow_call MUST be in the
#      known-exceptions whitelist below; unrecognised occurrences emit a WARNING but
#      do not fail the build, so a human can decide whether to whitelist or fix them.
#
# Usage: validate-workflow-naming.sh [repo-dir]

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [repo-dir]"
  exit 1
fi

repo_dir="${1:-$PWD}"
workflows_dir="$repo_dir/.github/workflows"

if [[ ! -d "$workflows_dir" ]]; then
  echo "Workflow directory '$workflows_dir' does not exist"
  exit 1
fi

# ---------------------------------------------------------------------------
# Rule 4 whitelist — non-common-*.yml workflows that are permitted to expose
# workflow_call for internal composition only (called locally within this
# repo, never by external consumers).  Add filenames (basename only) here
# when a new internal-composition workflow is introduced.
# ---------------------------------------------------------------------------
readonly INTERNAL_WORKFLOW_CALL_WHITELIST=(
  "verify-octopus-test-consumer.yml"  # called by check-octopus-test-consumer.yml
)

# Helper: return 0 if $1 is in the whitelist, 1 otherwise.
is_whitelisted() {
  local name="$1"
  local entry
  for entry in "${INTERNAL_WORKFLOW_CALL_WHITELIST[@]}"; do
    [[ "$entry" == "$name" ]] && return 0
  done
  return 1
}

failed=0

while IFS= read -r -d '' file; do
  # Rule 1: common-*.yml must have a workflow_call trigger.
  if ! grep -q 'workflow_call' "$file"; then
    echo "FAIL [no workflow_call] $file"
    failed=$((failed + 1))
  fi

  # Rule 2: common-*.yml must not reference actions/internal/.
  if grep -q 'actions/internal/' "$file"; then
    echo "FAIL [references actions/internal/] $file"
    grep -n 'actions/internal/' "$file" | while IFS= read -r match; do
      echo "  $match"
    done
    failed=$((failed + 1))
  fi

  # Rule 3: common-*.yml must not call a non-common local workflow.
  while IFS= read -r match; do
    # Extract the workflow path from the uses: value
    ref="${match#*uses:}"
    ref="${ref// /}"
    ref="${ref##*/}"  # keep only the filename
    if [[ "$ref" != common-* ]]; then
      echo "FAIL [calls non-common workflow: $ref] $file"
      failed=$((failed + 1))
    fi
  done < <(grep -E 'uses:[[:space:]]+\./.github/workflows/' "$file" || true)
done < <(find "$workflows_dir" -maxdepth 1 -type f -name 'common-*.yml' -print0 | sort -z)

if [[ "$failed" -ne 0 ]]; then
  echo "Workflow naming convention validation failed: ${failed} violation(s)."
  exit 1
fi

echo "All common-*.yml files pass naming convention checks."

# ---------------------------------------------------------------------------
# Rule 4 (advisory): warn about non-common-*.yml workflows that expose
# workflow_call but are not in the whitelist.
# ---------------------------------------------------------------------------
warnings=0
while IFS= read -r -d '' file; do
  basename_file="$(basename "$file")"
  if grep -q 'workflow_call' "$file"; then
    if ! is_whitelisted "$basename_file"; then
      echo "WARNING [non-common workflow exposes workflow_call — add to whitelist if intentional] $file"
      warnings=$((warnings + 1))
    fi
  fi
done < <(find "$workflows_dir" -maxdepth 1 -type f -name '*.yml' ! -name 'common-*.yml' -print0 | sort -z)

if [[ "$warnings" -ne 0 ]]; then
  echo "Rule 4 advisory: ${warnings} non-common workflow(s) expose workflow_call outside the whitelist. Review and update INTERNAL_WORKFLOW_CALL_WHITELIST if intentional."
fi
