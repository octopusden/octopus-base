#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <repo-dir> <tag>"
  exit 1
fi

repo_dir=$1
tag=$2
workflow_dir="$repo_dir/.github/workflows"

if [[ ! -d "$workflow_dir" ]]; then
  echo "Workflow directory '$workflow_dir' does not exist"
  exit 1
fi

workflow_files=()
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r workflow_file; do
    workflow_files+=("$workflow_file")
  done < <(
    rg -l "uses:\\s+octopusden/octopus-base/\\.github/actions/" \
      "$workflow_dir" \
      -g '*.yml' \
      -g '*.yaml' \
      | sort
  )
else
  while IFS= read -r -d '' workflow_file; do
    if grep -qE "uses:[[:space:]]+octopusden/octopus-base/\\.github/actions/" "$workflow_file"; then
      workflow_files+=("$workflow_file")
    fi
  done < <(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)

  if [[ ${#workflow_files[@]} -gt 0 ]]; then
    mapfile -t workflow_files < <(printf '%s\n' "${workflow_files[@]}" | sort)
  fi
fi

if [[ ${#workflow_files[@]} -eq 0 ]]; then
  echo "No internal octopus-base action references found under '$workflow_dir'"
  exit 0
fi

export SYNC_TAG="$tag"

for workflow_file in "${workflow_files[@]}"; do
  perl -0pi -e 's#(uses:\s+octopusden/octopus-base/\.github/actions/[^@\s]+@)[^\s]+#$1$ENV{SYNC_TAG}#g' \
    "$workflow_file"
done

printf 'Updated internal action refs to %s in %s file(s)\n' \
  "$tag" \
  "${#workflow_files[@]}"
