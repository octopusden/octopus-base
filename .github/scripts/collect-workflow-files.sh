#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <workflow-dir> <uses-regex>"
  exit 1
fi

workflow_dir=$1
uses_regex=$2

if [[ ! -d "$workflow_dir" ]]; then
  echo "Workflow directory '$workflow_dir' does not exist"
  exit 1
fi

if command -v rg >/dev/null 2>&1; then
  rg -l "$uses_regex" \
    "$workflow_dir" \
    -g '*.yml' \
    -g '*.yaml' \
    | sort
  exit 0
fi

{
  while IFS= read -r -d '' workflow_file; do
    if grep -qE "$uses_regex" "$workflow_file"; then
      printf '%s\n' "$workflow_file"
    fi
  done < <(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
} | sort
