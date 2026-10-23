#!/usr/bin/env bash
# No workflow or composite action may name the moving `ubuntu-latest` label, in `runs-on:` or as
# a runner-label input default: GitHub repoints it at a new Ubuntu release (26.04 in November
# 2026) and the tool versions under every job change with it. Comment lines are not checked.
# Scope: workflow and action YAML only; docs and agent prompts are not scanned.
set -uo pipefail

# An absent directory makes grep exit 2 with no output, which would read as a pass.
[[ -d .github/workflows && -d .github/actions ]] || { echo "FAIL: run from the repository root"; exit 1; }
# grep exits 1 for no match and 2 on any error, even alongside matches: only 1 is a pass.
grep -rnE '^[^#]*ubuntu-latest' .github/workflows .github/actions
[[ $? -eq 1 ]] || { echo "FAIL: ubuntu-latest above (or grep error); use ubuntu-24.04"; exit 1; }
echo "PASS no ubuntu-latest in .github/workflows or .github/actions"
