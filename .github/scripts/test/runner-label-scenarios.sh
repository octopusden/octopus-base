#!/usr/bin/env bash
# No workflow or composite action may name the moving `ubuntu-latest` label, in `runs-on:` or as
# a runner-label input default: GitHub repoints it at a new Ubuntu release (26.04 in November
# 2026) and the tool versions under every job change with it. Comment lines are not checked.
# Scope: workflow and action YAML only; docs and agent prompts are not scanned.
set -uo pipefail

# An absent directory makes grep exit 2 with no output, which would read as a pass.
[[ -d .github/workflows && -d .github/actions ]] || { echo "FAIL: run from the repository root"; exit 1; }
if grep -rnE '^[^#]*ubuntu-latest' .github/workflows .github/actions; then
  echo "FAIL: ubuntu-latest above; use ubuntu-24.04"
  exit 1
fi
echo "PASS no ubuntu-latest in .github/workflows or .github/actions"
