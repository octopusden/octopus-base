#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [repo-dir]"
  exit 1
fi

repo_dir="${1:-$PWD}"
workflows_dir="$repo_dir/.github/workflows"
actions_dir="$repo_dir/.github/actions"

if [[ ! -d "$workflows_dir" ]]; then
  echo "Workflow directory '$workflows_dir' does not exist"
  exit 1
fi

declare -a files=()
refs_file="$(mktemp)"
unique_refs_file="$(mktemp)"
trap 'rm -f "$refs_file" "$unique_refs_file"' EXIT

while IFS= read -r -d '' file; do
  files+=("$file")
done < <(find "$workflows_dir" -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 | sort -z)

if [[ -d "$actions_dir" ]]; then
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$actions_dir" -type f \( -name "action.yml" -o -name "action.yaml" \) -print0 | sort -z)
fi

invalid_format=0

for file in "${files[@]}"; do
  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))

    if [[ ! "$line" =~ ^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+) ]]; then
      continue
    fi

    uses_ref="${BASH_REMATCH[1]}"
    uses_ref="${uses_ref#\"}"
    uses_ref="${uses_ref%\"}"
    uses_ref="${uses_ref#\'}"
    uses_ref="${uses_ref%\'}"

    if [[ "$uses_ref" == ./* || "$uses_ref" == ../* || "$uses_ref" == docker://* ]]; then
      continue
    fi

    if [[ "$uses_ref" != *@* ]]; then
      echo "Invalid uses format (missing @ref): $uses_ref ($file:$line_no)"
      invalid_format=1
      continue
    fi

    source_part="${uses_ref%@*}"
    ref_part="${uses_ref##*@}"

    if [[ "$source_part" == *'${{'* || "$ref_part" == *'${{'* ]]; then
      echo "Dynamic uses reference is not allowed in this check: $uses_ref ($file:$line_no)"
      invalid_format=1
      continue
    fi

    owner="${source_part%%/*}"
    remainder="${source_part#*/}"
    repo="${remainder%%/*}"
    if [[ -z "${owner:-}" || -z "${repo:-}" ]]; then
      echo "Invalid uses repository format: $uses_ref ($file:$line_no)"
      invalid_format=1
      continue
    fi

    key="${owner}/${repo}@${ref_part}"
    printf '%s\t%s:%s\n' "$key" "$file" "$line_no" >> "$refs_file"
  done < "$file"
done

if [[ "$invalid_format" -ne 0 ]]; then
  echo "Action reference format validation failed."
  exit 1
fi

if [[ ! -s "$refs_file" ]]; then
  echo "No external GitHub action references found."
  exit 0
fi

LC_ALL=C sort -t $'\t' -k1,1 -u "$refs_file" > "$unique_refs_file"
unique_count="$(wc -l < "$unique_refs_file" | tr -d '[:space:]')"

echo "Validating ${unique_count} unique external GitHub action refs..."

failed=0
while IFS=$'\t' read -r key location; do
  owner_repo="${key%@*}"
  ref_part="${key##*@}"
  owner="${owner_repo%/*}"
  repo="${owner_repo#*/}"
  encoded_ref="$(jq -nr --arg value "$ref_part" '$value|@uri')"

  attempt=1
  max_attempts=3
  check_ok=0
  check_error=""
  while (( attempt <= max_attempts )); do
    if check_output="$(gh api "repos/${owner}/${repo}/commits/${encoded_ref}" --jq .sha 2>&1)"; then
      check_ok=1
      break
    fi

    check_error="$check_output"
    if (( attempt < max_attempts )); then
      sleep $((attempt * 2))
    fi
    attempt=$((attempt + 1))
  done

  if [[ "$check_ok" -eq 1 ]]; then
    echo "OK   ${key}"
  else
    echo "FAIL ${key} (first seen at ${location})"
    echo "  reason: ${check_error}"
    failed=$((failed + 1))
  fi
done < "$unique_refs_file"

if [[ "$failed" -ne 0 ]]; then
  echo "Found ${failed} unresolved external action reference(s)."
  exit 1
fi

echo "All external action refs are resolvable."
