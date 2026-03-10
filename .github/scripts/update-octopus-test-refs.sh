#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <octopus-test-repo-dir> <octopus-base-ref>"
  exit 1
fi

repo_dir=$1
octopus_base_ref=$2
workflow_dir="$repo_dir/.github/workflows"

if [[ ! -d "$workflow_dir" ]]; then
  echo "Workflow directory '$workflow_dir' does not exist"
  exit 1
fi

workflow_files=()
while IFS= read -r workflow_file; do
  workflow_files+=("$workflow_file")
done < <(
  rg -l "uses:\\s+octopusden/octopus-base/\\.github/workflows/" \
    "$workflow_dir" \
    -g '*.yml' \
    -g '*.yaml' \
    | sort
)

if [[ ${#workflow_files[@]} -eq 0 ]]; then
  echo "No octopus-base reusable workflow references found under '$workflow_dir'"
  exit 1
fi

export OCTOPUS_BASE_REF="$octopus_base_ref"

for workflow_file in "${workflow_files[@]}"; do
  perl -0pi -e 's#(uses:\s+octopusden/octopus-base/\.github/workflows/[^@\s]+@)[^\s]+#$1$ENV{OCTOPUS_BASE_REF}#g' \
    "$workflow_file"
done

printf 'Updated octopus-base workflow refs to %s in %s file(s)\n' \
  "$octopus_base_ref" \
  "${#workflow_files[@]}"
