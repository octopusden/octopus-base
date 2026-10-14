#!/usr/bin/env bash
#
# Scenario tests for the "Shared packages credentials" step, which every Gradle job of the
# reusable workflows that offer resolve-from-shared-packages carries a copy of.
#
# consumer-verify cannot cover it: octopus-test does not opt in, so CI never runs the step's body.
# These scenarios pin what the copies must keep in common, then EXTRACT one body and execute it,
# so there is no second copy here to drift.
#
#   - every copy is identical, gated on the input, and reads the read-only secret
#   - in each job it comes before the first step that can run Gradle
#   - each workflow that has the input declares the secret, and none of its Gradle jobs lacks the step
#   - opted in without the token: the job fails, names the secret, and writes nothing to GITHUB_ENV
#   - opted in with the token: both variables reach GITHUB_ENV and the token is not printed
#
# Usage: bash .github/scripts/test/shared-packages-credentials-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

pass=0; fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
body="$tmp/body.sh"

echo "-- the copies, against the workflow files ----------------------------------"
python3 - "$root/.github/workflows" "$body" <<'PY'
import glob, io, os, re, sys
wf_dir, out = sys.argv[1], sys.argv[2]

STEP = "- name: Shared packages credentials"
GATE = "if: ${{ inputs.resolve-from-shared-packages }}"
SECRET = "READ_TOKEN: ${{ secrets.OCTOPUS_SHARED_PACKAGES_READ_TOKEN }}"
# Anything that can start Gradle: the wrapper, the actions that drive it, CodeQL's autobuild, and
# the `*-command` inputs whose defaults are ./gradlew invocations.
GRADLE = re.compile(r"gradlew|gradle/actions/setup-gradle|gradle/actions/dependency-submission"
                    r"|codeql-action/autobuild|run: \$\{\{ inputs\.[a-z-]+-command \}\}")
# The workflows that offer the opt-in. Pinned, so dropping the input from one fails here instead
# of silently shrinking what is checked.
EXPECTED = {
    "common-gradle-dependency-submission.yml",
    "common-java-gradle-build.yml",
    "common-java-gradle-quality-gates.yml",
    "common-java-gradle-release.yml",
    "common-java-gradle-security-reports.yml",
    "common-java-gradle-sonar.yml",
}

problems, copies = [], []

def jobs_of(lines):
    """(name, first line, end line) of each job under `jobs:`, by indentation."""
    start = next((i for i, l in enumerate(lines) if l.rstrip() == "jobs:"), None)
    if start is None:
        return []
    heads = [i for i in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])]
    return [(lines[h].strip()[:-1], h, heads[k + 1] if k + 1 < len(heads) else len(lines))
            for k, h in enumerate(heads)]

def step_block(lines, at):
    """The step that starts at `at`, up to the next step of the same indentation."""
    indent = len(lines[at]) - len(lines[at].lstrip())
    end = at + 1
    while end < len(lines):
        l = lines[end]
        if l.strip() and len(l) - len(l.lstrip()) <= indent:
            break
        end += 1
    while end > at and not lines[end - 1].strip():
        end -= 1  # a blank line before the next step is layout, not part of the step
    return [l[indent:] for l in lines[at:end]]

found = set()
for path in sorted(glob.glob(os.path.join(wf_dir, "common-*.yml"))):
    name = os.path.basename(path)
    lines = io.open(path, encoding="utf-8").read().splitlines()
    if not any(l.strip() == "resolve-from-shared-packages:" for l in lines):
        if any(l.strip() == STEP for l in lines):
            problems.append("%s: carries the step but has no resolve-from-shared-packages input" % name)
        continue
    found.add(name)
    if not any(l.strip() == "OCTOPUS_SHARED_PACKAGES_READ_TOKEN:" for l in lines):
        problems.append("%s: has the input but declares no OCTOPUS_SHARED_PACKAGES_READ_TOKEN secret" % name)
    for job, first, end in jobs_of(lines):
        steps_at = next((i for i in range(first, end) if lines[i].strip() == "steps:"), None)
        if steps_at is None:
            continue  # a job that calls another workflow
        gradle_at = next((i for i in range(steps_at, end) if GRADLE.search(lines[i])), None)
        step_at = [i for i in range(steps_at, end) if lines[i].strip() == STEP]
        if gradle_at is None:
            if step_at:
                problems.append("%s/%s: carries the step but runs no Gradle" % (name, job))
            continue
        if len(step_at) != 1:
            problems.append("%s/%s: runs Gradle (line %d) but has %d copies of the step"
                            % (name, job, gradle_at + 1, len(step_at)))
            continue
        if step_at[0] > gradle_at:
            problems.append("%s/%s: the step (line %d) comes after Gradle can run (line %d)"
                            % (name, job, step_at[0] + 1, gradle_at + 1))
        block = step_block(lines, step_at[0])
        copies.append(("%s/%s" % (name, job), block))

if found != EXPECTED:
    problems.append("workflows offering the input changed: missing %s, unexpected %s"
                    % (sorted(EXPECTED - found) or "none", sorted(found - EXPECTED) or "none"))
if not copies:
    problems.append("no copy of the step found")
else:
    ref_where, ref = copies[0]
    for where, block in copies[1:]:
        if block != ref:
            problems.append("%s differs from %s" % (where, ref_where))
    stripped = [l.strip() for l in ref]
    if GATE not in stripped:
        problems.append("the step's if: is not %r" % GATE)
    if SECRET not in stripped:
        problems.append("the step does not read %r" % SECRET)
    if "run: |" not in stripped:
        problems.append("the step has no 'run: |' body")
    if any(l.startswith("shell:") for l in stripped):
        problems.append("the scenarios model bash; the step now declares a shell")

for p in problems:
    print("FAIL  " + p)
if problems:
    sys.exit(1)
print("PASS  %d copies across %d workflows are identical, gated, and ahead of Gradle"
      % (len(copies), len(found)))

run = stripped.index("run: |")
indent = len(ref[run]) - len(ref[run].lstrip()) + 2
script = [l[indent:] if l.startswith(" " * indent) else l.strip() for l in ref[run + 1:]]
io.open(out, "w", encoding="utf-8").write("\n".join(script) + "\n")
PY
[ $? = 0 ] && pass=$((pass+1)) || { echo; echo "0 passed, 1 failed"; exit 1; }
[ -s "$body" ] || { echo "FAIL  could not extract the step body"; exit 1; }

# A `run:` with no `shell:` on Linux runs as `bash -e {0}`.
RUNNER_SHELL=(bash --noprofile --norc -e)

# run <name> <expected-rc> <must-match-in-output> <check-on-GITHUB_ENV>
#   TOKEN  READ_TOKEN for the step (unset when empty, as GitHub passes an absent secret)
run() {
  local name="$1" erc="$2" want="$3" check="$4"
  local dir="$tmp/$pass-$fail" out rc ok=true
  mkdir -p "$dir"; out="$dir/out.txt"; : > "$dir/github_env"
  ( cd "$dir" && READ_TOKEN="${TOKEN-}" GITHUB_REPOSITORY_OWNER=octopusden GITHUB_ENV="$dir/github_env" \
      "${RUNNER_SHELL[@]}" "$body" ) >"$out" 2>&1
  rc=$?
  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing in output: $want"; }
  ( cd "$dir" && eval "$check" ) || { ok=false; echo "  GITHUB_ENV check failed: $check"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1))
    sed 's/^/    | out: /' "$out"; sed 's/^/    | env: /' "$dir/github_env"
  fi
}

echo "-- the body, executed ------------------------------------------------------"
TOKEN='' run "no token: fails early and names the secret" 1 \
  "::error title=No token for the shared packages registry::.*OCTOPUS_SHARED_PACKAGES_READ_TOKEN" \
  '[ ! -s github_env ]'
TOKEN='' run "no token: the message points at fork and Dependabot pull requests" 1 \
  "fork.*Dependabot secret of the same name" \
  'true'
TOKEN=ghp_fixtureReadToken run "token: exports exactly the two variables" 0 "" \
  '[ "$(cat github_env)" = "$(printf "SHARED_PACKAGES_READ_USERNAME=octopusden\nSHARED_PACKAGES_READ_TOKEN=ghp_fixtureReadToken")" ]'
TOKEN=ghp_fixtureReadToken run "token: never printed to the log" 0 "" \
  '! grep -q ghp_fixtureReadToken out.txt'
TOKEN=ghp_fixtureReadToken run "token: names do not collide with the publish credential" 0 "" \
  '! grep -q "^GITHUB_PACKAGES_" github_env'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
