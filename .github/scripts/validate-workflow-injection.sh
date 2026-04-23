#!/usr/bin/env bash
# validate-workflow-injection.sh — Detect unsafe expression interpolation in workflow run: blocks.
#
# Shell injection vector: ${{ inputs.* }} or ${{ github.event.* }} used directly
# inside a run: shell block — an attacker-controlled value is interpolated as code.
#
# Safe pattern: assign the expression to an env: variable and reference it as $VARNAME
# inside the run: block.  The env: and with: contexts are NOT flagged.
#
# Usage:
#   validate-workflow-injection.sh [repo-dir]
#
# Exit codes:
#   0  — no violations found (or all findings are whitelisted)
#   1  — one or more non-whitelisted violations found
#
# Whitelist:
#   .github/scripts/workflow-injection-whitelist.txt — list of "relative/path:lineno"
#   pairs (one per line, comments with # allowed) that are explicitly allowed.
#   Paths are relative to repo-dir.

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [repo-dir]"
  exit 1
fi

repo_dir="${1:-$PWD}"
# Normalise to absolute path without trailing slash
repo_dir="$(cd "$repo_dir" && pwd)"
workflows_dir="$repo_dir/.github/workflows"
whitelist_file="$repo_dir/.github/scripts/workflow-injection-whitelist.txt"

if [[ ! -d "$workflows_dir" ]]; then
  echo "Workflow directory '$workflows_dir' does not exist"
  exit 1
fi

# ---------------------------------------------------------------------------
# Dangerous expression patterns — user-controlled values that must not appear
# directly inside a run: shell block.
# ---------------------------------------------------------------------------
# inputs.*            — caller-supplied strings (arbitrary content)
# github.event.pull_request.title / .body / .head.ref — PR metadata (attacker-controlled)
# github.event.pull_request.head.ref  — branch name chosen by attacker
# github.event.issue.title / .body    — issue content (attacker-controlled)
# github.event.comment.body           — comment content (attacker-controlled)
# github.head_ref                     — alias for PR head branch (attacker-controlled)
# ---------------------------------------------------------------------------
readonly DANGEROUS_PATTERN='\$\{\{[[:space:]]*(inputs\.[^}]+|github\.event\.(pull_request\.(title|body|head\.ref)|issue\.(title|body)|comment\.body)|github\.head_ref)[[:space:]]*\}\}'

# ---------------------------------------------------------------------------
# Load whitelist entries — newline-delimited for bash 3 compatibility.
# Each entry is "relative/path/to/file:lineno" relative to repo_dir.
# ---------------------------------------------------------------------------
_whitelist_entries=""
if [[ -f "$whitelist_file" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"  # strip comments
    line="${line// /}"  # strip spaces
    [[ -z "$line" ]] && continue
    _whitelist_entries="${_whitelist_entries}${line}"$'\n'
  done < "$whitelist_file"
fi

is_whitelisted() {
  local rel_path="$1"   # "relative/path/to/file:lineno"
  # Exact line match: wrap both sides with newlines so file:71 doesn't match file:711.
  case $'\n'"${_whitelist_entries}" in
    *$'\n'"${rel_path}"$'\n'*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# State-machine parser: tracks YAML context to distinguish run: from env:/with:.
#
# Contexts:
#   OUTSIDE — normal YAML (not inside any block of interest)
#   RUN     — inside a run: | or run: > block (shell code — flagged)
#   ENV     — inside an env: block at step level (safe: assignments only)
#   WITH    — inside a with: block at step level (not shell context)
#
# Block ends when a line's indentation is <= the indent that opened the block.
# ---------------------------------------------------------------------------

violations=0

process_file() {
  local file="$1"
  # Relative path for whitelist lookups
  local rel_file="${file#"$repo_dir/"}"
  local lineno=0
  local context="OUTSIDE"
  local block_indent=-1

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    lineno=$((lineno + 1))

    # Measure leading spaces (YAML indentation).
    stripped="${raw_line#"${raw_line%%[! ]*}"}"
    leading=$(( ${#raw_line} - ${#stripped} ))

    # Blank lines and comment lines do not change context.
    if [[ -z "$stripped" || "$stripped" == \#* ]]; then
      continue
    fi

    # Normalize YAML list marker: "- run: ..." is the same step key as "run: ...".
    # We strip an optional leading "- " before matching step keys; the indent
    # tracking still uses the position of the "-" character, which is what
    # GitHub Actions treats as the step's level.
    key_line="$stripped"
    if [[ "$key_line" =~ ^-[[:space:]]+ ]]; then
      key_line="${key_line#- }"
      key_line="${key_line#"${key_line%%[! ]*}"}"
    fi

    # Leaving a block: indent dropped back to or past the opener level.
    if [[ "$context" != "OUTSIDE" && "$leading" -le "$block_indent" ]]; then
      context="OUTSIDE"
      block_indent=-1
    fi

    if [[ "$context" == "OUTSIDE" ]]; then
      case "$key_line" in
        run:*|run:)
          context="RUN"
          block_indent="$leading"
          # Handle inline single-line run value (no block scalar "|" or ">")
          inline="${key_line#run:}"
          inline="${inline#"${inline%%[! ]*}"}"  # trim leading space
          # First token only (drop YAML trailing comment like `run: | # comment`)
          # so "run: | # foo" is recognized as a block scalar, not an inline run.
          first_token="${inline%%[[:space:]]*}"
          first_token="${first_token%%#*}"
          # YAML block scalars: |, >, with optional chomp (-/+) and/or indent (digit)
          # Matches: | > |- |+ >- >+ |2 |4- >2+ etc.
          if [[ -n "$inline" && ! "$first_token" =~ ^[|\>][+\-]?[0-9]?$ && ! "$first_token" =~ ^[|\>][0-9][+\-]?$ ]]; then
            if echo "$inline" | grep -qE "$DANGEROUS_PATTERN"; then
              local wl_key="${rel_file}:${lineno}"
              if ! is_whitelisted "$wl_key"; then
                echo "FAIL [injection] ${rel_file}:${lineno}: ${raw_line}"
                echo "     Hint: move the expression to an env: block and reference it as \$VAR in run:"
                violations=$((violations + 1))
              fi
            fi
            # Single-line run: — no block to enter
            context="OUTSIDE"
            block_indent=-1
          fi
          continue
          ;;
        env:)
          context="ENV"
          block_indent="$leading"
          continue
          ;;
        with:)
          context="WITH"
          block_indent="$leading"
          continue
          ;;
      esac
    fi

    # Inside a RUN block: flag any dangerous expression.
    if [[ "$context" == "RUN" ]]; then
      if echo "$raw_line" | grep -qE "$DANGEROUS_PATTERN"; then
        local wl_key="${rel_file}:${lineno}"
        if ! is_whitelisted "$wl_key"; then
          echo "FAIL [injection] ${rel_file}:${lineno}: ${raw_line}"
          echo "     Hint: move the expression to an env: block and reference it as \$VAR in run:"
          violations=$((violations + 1))
        fi
      fi
    fi
    # ENV and WITH blocks: safe contexts — intentionally not scanned.

  done < "$file"
}

while IFS= read -r -d '' file; do
  process_file "$file"
done < <(find "$workflows_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z)

if [[ "$violations" -ne 0 ]]; then
  echo ""
  echo "Workflow injection safety check failed: ${violations} violation(s)."
  echo "Safe pattern: assign the value to an env: variable, then use \$VAR_NAME in run:."
  echo "Example:"
  echo "  env:"
  echo "    MY_INPUT: \${{ inputs.my-input }}"
  echo "  run: |"
  echo "    echo \"\$MY_INPUT\""
  echo "To suppress a known-safe exception add the file:lineno to .github/scripts/workflow-injection-whitelist.txt"
  exit 1
fi

echo "All workflow files pass injection safety check."
