#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <repo-dir> <tag>"
  exit 1
fi

repo_dir=$1
tag=$2
workflow_dir="$repo_dir/.github/workflows"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
collect_script="${script_dir}/collect-workflow-files.sh"

if [[ ! -d "$workflow_dir" ]]; then
  echo "Workflow directory '$workflow_dir' does not exist"
  exit 1
fi

workflow_files=()
while IFS= read -r workflow_file; do
  workflow_files+=("$workflow_file")
done < <(bash "$collect_script" "$workflow_dir" "uses:[[:space:]]+octopusden/octopus-base/\\.github/actions/")

if [[ ${#workflow_files[@]} -eq 0 ]]; then
  # This sync is optional: if no internal refs exist, release can continue.
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
