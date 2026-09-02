#!/usr/bin/env bash
#
# Scenario tests for the "Guard against publishing fat jars to Maven Central" step in
# .github/workflows/common-java-gradle-release.yml.
#
# The step's logic is not a file: it is the `run:` body in the workflow. These scenarios
# EXTRACT that body and execute it, so there is no second copy to drift — and the extraction
# fails loudly rather than silently testing nothing.
#
# `./gradlew` is a stub that records its argv, and the helper inspector is a stub whose exit
# code and recorded environment are the fixture. That makes reachable the branch nothing else
# covers: the inspector missing from disk, which must stop a real release and only warn in a
# dry run. Before this suite that asymmetry was the one contract in the change with no test —
# the dry-run half is exercised by the release smoke, the failing half by nothing.
#
# Usage: bash .github/scripts/test/publication-guard-step-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../../.."
workflow="$root/.github/workflows/common-java-gradle-release.yml"
[ -f "$workflow" ] || { echo "workflow not found: $workflow"; exit 1; }

pass=0; fail=0

body="$(mktemp)"
python3 - "$workflow" "$body" <<'PY'
import io, sys
workflow, out = sys.argv[1], sys.argv[2]
lines = io.open(workflow, encoding="utf-8").read().splitlines()
name = "- name: Guard against publishing fat jars to Maven Central"
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == name)
except StopIteration:
    sys.exit("step not found: " + name)
run = next((i for i in range(start, len(lines)) if lines[i].strip() == "run: |"), None)
if run is None:
    sys.exit("step has no 'run: |' body")
indent = len(lines[run]) - len(lines[run].lstrip()) + 2
collected = []
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(" " * indent):
        break
    collected.append(line[indent:] if len(line) > indent else line.strip())
script = "\n".join(collected) + "\n"
for required in ("publishToMavenLocal", "inspect-publication-set.py", "GUARD_REPO"):
    if required not in script:
        sys.exit("extracted body lacks %r; extraction is wrong" % required)
io.open(out, "w", encoding="utf-8").write(script)
PY
[ -s "$body" ] || { echo "could not extract the step body"; exit 1; }

# run <name> <expected-rc> <must-match> [<must-not-match>]
#   HELPER=missing        do not create the inspector on disk
#   GRADLE_RC, INSPECT_RC exit codes for the stubs
#   DRY                   DRY_RUN for the step
#   STALE=1               leave a file inside the guard repository before the step runs
#   CHECK                 extra shell run after the step, in $dir, to assert side effects
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  local dir out rc ok=true
  dir="$(mktemp -d)"; out="$dir/out.txt"
  mkdir -p "$dir/ws" "$dir/runner-temp"

  cat > "$dir/ws/gradlew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV"
exit "${GRADLE_RC:-0}"
STUB
  chmod +x "$dir/ws/gradlew"

  if [ "${HELPER:-present}" != "missing" ]; then
    mkdir -p "$dir/ws/.octopus-base-helper/.github/scripts"
    cat > "$dir/ws/.octopus-base-helper/.github/scripts/inspect-publication-set.py" <<'STUB'
import os, sys
with open(os.environ["INSPECTED"], "a") as f:
    f.write("argv=%s DRY_RUN=%s ALLOWLIST=%s MAX_MB=%s\n" % (
        " ".join(sys.argv[1:]), os.environ.get("DRY_RUN"),
        os.environ.get("FAT_JAR_ALLOWLIST"), os.environ.get("MAX_ARTIFACT_MB")))
sys.exit(int(os.environ.get("INSPECT_RC", "0")))
STUB
  fi

  [ "${STALE:-}" = "1" ] && { mkdir -p "$dir/runner-temp/m2-publication-guard"; echo stale > "$dir/runner-temp/m2-publication-guard/leftover.jar"; }

  ( cd "$dir/ws" && \
      ARGV="$dir/argv" INSPECTED="$dir/inspected" \
      GRADLE_RC="${GRADLE_RC:-0}" INSPECT_RC="${INSPECT_RC:-0}" \
      RUNNER_TEMP="$dir/runner-temp" BUILD_VERSION=2.0.105 \
      DRY_RUN="${DRY:-false}" FAT_JAR_ALLOWLIST="${ALLOWLIST:-}" MAX_ARTIFACT_MB="${MAX_MB:-8}" \
      bash "$body" ) >"$out" 2>&1
  rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if [ -n "${CHECK:-}" ]; then
    ( cd "$dir" && eval "$CHECK" ) || { ok=false; echo "  side-effect check failed: $CHECK"; }
  fi
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
    echo "    | gradlew argv: $(cat "$dir/argv" 2>/dev/null)"
    echo "    | inspector:    $(cat "$dir/inspected" 2>/dev/null)"
  fi
  rm -rf "$dir"
}

echo "-- the branch nothing else covers: the inspector is not on disk -----------"
HELPER=missing DRY=false \
  run "a real release refuses when the inspector is missing" 1 "::error title=Cannot inspect the publication set::"
HELPER=missing DRY=true \
  run "a dry run warns and continues when the inspector is missing" 0 "::warning title=Publication set not inspected::" "::error"
HELPER=missing DRY=false CHECK='[ ! -s inspected ]' \
  run "and nothing is inspected in that case" 1 "Refusing to publish unverified artifacts"

echo "-- the inspector's verdict is the step's verdict --------------------------"
INSPECT_RC=0 CHECK='grep -q "argv=.*m2-publication-guard" inspected' \
  run "a fit set passes, and the inspector was given the guard repository" 0 ""
INSPECT_RC=1 \
  run "an unfit set fails the step" 1 ""
DRY=true INSPECT_RC=1 CHECK='grep -q "DRY_RUN=true" inspected' \
  run "a dry run still inspects, and says so to the inspector" 1 ""
ALLOWLIST=automation MAX_MB=32 CHECK='grep -q "ALLOWLIST=automation MAX_MB=32" inspected' \
  run "the allowlist and the size limit reach the inspector" 0 ""

echo "-- the dry publication that feeds it --------------------------------------"
GRADLE_RC=1 CHECK='[ ! -s inspected ]' \
  run "a failed dry publication fails the step before inspecting anything" 1 ""
CHECK='grep -q -- "-Pnexus=true" argv' \
  run "the dry publication passes -Pnexus=true, as the real upload does" 0 ""
CHECK='grep -q -- "-Dmaven.repo.local=.*m2-publication-guard" argv' \
  run "it publishes into the throwaway repository, not the real local one" 0 ""
CHECK='grep -q -- "-PbuildVersion=2.0.105 -Pversion=2.0.105" argv' \
  run "it publishes the release version" 0 ""
CHECK='grep -q -- "--init-script .*no-signing.init.gradle" argv && grep -q "required = false" runner-temp/no-signing.init.gradle' \
  run "signing is force-disabled, so the guard needs no GPG key" 0 ""
STALE=1 CHECK='grep -q "argv=" inspected && [ ! -f runner-temp/m2-publication-guard/leftover.jar ]' \
  run "a leftover guard repository is cleared, so nothing stale is inspected" 0 ""

rm -f "$body"
echo
echo "publication-guard-step scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
