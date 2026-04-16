#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <octopus-test-repo-dir> <octopus-base-ref>"
  exit 1
fi

repo_dir=$1
octopus_base_ref=$2
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
done < <(bash "$collect_script" "$workflow_dir" "uses:[[:space:]]+octopusden/octopus-base/\\.github/workflows/")

if [[ ${#workflow_files[@]} -eq 0 ]]; then
  echo "No octopus-base reusable workflow references found under '$workflow_dir'"
  # Don't exit yet — action refs may still need rewriting.
fi

export OCTOPUS_BASE_REF="$octopus_base_ref"

if [[ ${#workflow_files[@]} -gt 0 ]]; then
  for workflow_file in "${workflow_files[@]}"; do
    perl -0pi -e 's#(uses:\s+octopusden/octopus-base/\.github/workflows/[^@\s]+@)[^\s]+#$1$ENV{OCTOPUS_BASE_REF}#g' \
      "$workflow_file"
  done
  printf 'Updated octopus-base workflow refs to %s in %s file(s)\n' \
    "$octopus_base_ref" \
    "${#workflow_files[@]}"
fi

# --- Action ref rewriting ---
# Scan ALL workflow files (not just those with workflow refs) for action refs.
all_workflow_files=()
while IFS= read -r -d '' f; do
  all_workflow_files+=("$f")
done < <(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

action_files=()
for wf in "${all_workflow_files[@]}"; do
  if grep -qE 'uses:[[:space:]]+octopusden/octopus-base/\.github/actions/' "$wf"; then
    action_files+=("$wf")
  fi
done

if [[ ${#action_files[@]} -eq 0 ]]; then
  echo "No action refs found, skipping"
else
  echo "Rewriting ${#action_files[@]} action ref(s)"
  for action_file in "${action_files[@]}"; do
    perl -0pi -e 's#(uses:\s+octopusden/octopus-base/\.github/actions/[^@\s]+@)[^\s]+#$1$ENV{OCTOPUS_BASE_REF}#g' \
      "$action_file"
  done
fi

# Fail if neither workflow nor action refs were found — nothing was rewritten.
if [[ ${#workflow_files[@]} -eq 0 ]] && [[ ${#action_files[@]} -eq 0 ]]; then
  echo "No octopus-base refs (workflow or action) found under '$workflow_dir'"
  exit 1
fi

# --- Convention plugin version bump ---
if [[ -z "${OCTOPUS_QUALITY_VERSION:-}" ]]; then
  echo "OCTOPUS_QUALITY_VERSION not set, skipping plugin version bump"
else
  if [[ ! "${OCTOPUS_QUALITY_VERSION}" =~ ^[0-9A-Za-z._+-]+$ ]]; then
    echo "Invalid OCTOPUS_QUALITY_VERSION: '${OCTOPUS_QUALITY_VERSION}'"
    exit 1
  fi

  settings_file=""
  for candidate in "$repo_dir/settings.gradle.kts" "$repo_dir/settings.gradle"; do
    if [[ -f "$candidate" ]]; then
      settings_file="$candidate"
      break
    fi
  done

  if [[ -z "$settings_file" ]]; then
    echo "OCTOPUS_QUALITY_VERSION set but no settings.gradle(.kts) found under '$repo_dir' — skipping"
  elif ! grep -qE 'org\.octopusden\.octopus-quality["\x27]' "$settings_file"; then
    echo "OCTOPUS_QUALITY_VERSION set but no org.octopusden.octopus-quality declaration in $settings_file — skipping"
  else
    perl -pi -e 's#(org\.octopusden\.octopus-quality["\x27].*?version\s*\(?\s*["\x27])([^"'"'"']+)(["\x27])#${1}$ENV{OCTOPUS_QUALITY_VERSION}${3}#g' \
      "$settings_file"
    if grep -qF "${OCTOPUS_QUALITY_VERSION}" "$settings_file"; then
      printf 'Updated octopus-quality plugin version to %s in %s\n' \
        "$OCTOPUS_QUALITY_VERSION" \
        "$settings_file"
    else
      echo "Failed to update octopus-quality plugin version to ${OCTOPUS_QUALITY_VERSION} in ${settings_file}"
      exit 1
    fi
  fi
fi
