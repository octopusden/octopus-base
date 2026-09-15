#!/usr/bin/env bash
#
# Scenario tests for the "Validate shared packages registry" step in
# .github/workflows/common-java-gradle-release.yml.
#
# The step's logic is not a file: it is the `run:` body in the workflow. These scenarios
# EXTRACT that body and execute it, so there is no second copy to drift — and the extraction
# fails loudly rather than silently testing nothing.
#
# The contract has two halves that must not collapse into each other. The shape check runs
# ALWAYS, dry run included, because a malformed destination is a defect whether or not this run
# publishes. The credential checks run only on a REAL release, because a dry run publishes
# nothing and requiring a secret it will not use stops a rehearsal from a context that holds
# none. Nothing else covers either half.
#
# Usage: bash .github/scripts/test/shared-packages-validation-scenarios.sh   (from the repo root)

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
name = "- name: Validate shared packages registry"
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
for required in ("PACKAGES_REPOSITORY", "SHARED_PACKAGES_TOKEN", "DRY_RUN", "gh api"):
    if required not in script:
        sys.exit("extracted body lacks %r; extraction is wrong" % required)
# The `if:` is part of the contract, not decoration: the step must not run at all for a caller
# that names no shared registry, and the scenarios cannot exercise `if:` themselves — GitHub
# evaluates it. Pinned here so deleting the gate cannot leave every scenario green.
gate = next((lines[i].strip() for i in range(start, run) if lines[i].strip().startswith("if:")), "")
if "inputs.github-packages-repository != ''" not in gate:
    sys.exit("step's if: lost the github-packages-repository gate; it now reads %r" % gate)
# The step must stay ahead of every irreversible side effect. Asserted against the file rather
# than described in a comment, because the ordering is the reason the step exists.
def step_line(label):
    return next((i for i in range(len(lines)) if lines[i].strip() == "- name: " + label), None)
for later in ("Publish to Sonatype Nexus", "Publish deployment via Central Portal",
              "Publish to GitHub Packages"):
    at = step_line(later)
    if at is not None and at < start:
        sys.exit("validation runs AFTER %r; a bad destination would be found past a publish" % later)
shell = next((lines[i].strip() for i in range(start, run) if lines[i].strip().startswith("shell:")), None)
if shell not in ("shell: bash", None):
    sys.exit("scenarios only model bash; step declares %r" % shell)
io.open(out, "w", encoding="utf-8").write(script)
io.open(out + ".shell", "w", encoding="utf-8").write(shell or "shell: bash (implicit default)")
PY
[ -s "$body" ] || { echo "could not extract the step body"; exit 1; }

if [ "$(cat "$body.shell")" = "shell: bash" ]; then
  RUNNER_SHELL=(bash --noprofile --norc -eo pipefail)
else
  RUNNER_SHELL=(bash --noprofile --norc -e)
fi
echo "step declares: $(cat "$body.shell")"
echo "running it as: ${RUNNER_SHELL[*]} <body>"

# run <name> <expected-rc> <must-match> [<must-not-match>]
#   REPO    PACKAGES_REPOSITORY for the step
#   TOKEN   SHARED_PACKAGES_TOKEN for the step
#   DRY     DRY_RUN for the step
#   GH_RC   exit code of the stubbed `gh`, i.e. whether the probe is refused
#   CHECK   extra shell run afterwards, in $dir, to assert what the probe was given
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  local dir out rc ok=true
  dir="$(mktemp -d)"; out="$dir/out.txt"

  # A purpose-built stub rather than the shared one beside it: that fixture answers the
  # release-version lookups and nothing here. It records its argv AND the token it was handed,
  # so "the probe ran" and "the probe ran against the right repository with the right secret"
  # are separate assertions — a probe invoked with an empty GH_TOKEN would otherwise look fine.
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s token=%s\n' "$*" "${GH_TOKEN-}" >> "$PROBED"
exit "${GH_RC:-0}"
STUB
  chmod +x "$dir/bin/gh"

  ( cd "$dir" && PATH="$dir/bin:$PATH" \
      PROBED="$dir/probed" GH_RC="${GH_RC:-0}" \
      PACKAGES_REPOSITORY="${REPO-}" SHARED_PACKAGES_TOKEN="${TOKEN-}" DRY_RUN="${DRY:-false}" \
      "${RUNNER_SHELL[@]}" "$body" ) >"$out" 2>&1
  rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if [ -n "${CHECK:-}" ]; then
    ( cd "$dir" && eval "$CHECK" ) || { ok=false; echo "  probe check failed: $CHECK"; }
  fi
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
    echo "    | probe: $(cat "$dir/probed" 2>/dev/null || echo '(never invoked)')"
  fi
  rm -rf "$dir"
}

echo "-- the shape check runs always, dry run included --------------------------"
# GitHub's Maven registry does not support an uppercase owner, and the value reaches the URL
# through a workflow expression, which has no lower() to normalise it with. Accepting one here
# is precisely the failure the step exists to prevent: it survives preflight and is refused at
# the upload, after Central.
REPO=OctopusDen/octopus-maven-packages TOKEN=t DRY=false \
  run "rejects an uppercase owner on a real release" 1 "is not OWNER/REPO with a lowercase owner"
REPO=OctopusDen/octopus-maven-packages TOKEN= DRY=true \
  run "rejects an uppercase owner on a DRY RUN too" 1 "is not OWNER/REPO with a lowercase owner"
REPO=octopusden/Octopus-Maven-Packages TOKEN=t DRY=false \
  run "accepts an uppercase REPOSITORY name — only the owner is constrained" 0 "maven\.pkg\.github\.com/octopusden/Octopus-Maven-Packages"
REPO=octopus-maven-packages TOKEN=t DRY=false \
  run "rejects a value that is not two path segments" 1 "is not OWNER/REPO"
REPO=octopusden/octopus/maven-packages TOKEN=t DRY=false \
  run "rejects three path segments" 1 "is not OWNER/REPO"
REPO= TOKEN=t DRY=false \
  run "rejects an empty destination" 1 "is not OWNER/REPO"

echo "-- a dry run stops after the shape check ---------------------------------"
# The rehearsal must not require a credential it will not use — a caller dry-running from a
# context with no secrets would otherwise be unable to. The probe must not run either: it is a
# network call, and a dry run has nothing to authenticate.
REPO=octopusden/octopus-maven-packages TOKEN= DRY=true \
  CHECK='[ ! -s probed ]' \
  run "passes a dry run with no token, and never probes" 0 "Dry run: destination shape checked" "::error"

echo "-- a real release refuses before anything is published --------------------"
# The case the step exists for. A missing credential discovered at the upload is discovered
# after Central, which cannot be undone, and arrives as a 401/404 that a Maven client reports
# as "version does not exist".
REPO=octopusden/octopus-maven-packages TOKEN= DRY=false \
  CHECK='[ ! -s probed ]' \
  run "refuses a real release when the token is unset, without probing" 1 "::error title=SHARED_PACKAGES_TOKEN is not set::"

# Presence is not validity. An expired or revoked token passes the check above, so without this
# it reaches the upload — the rotation failure, and the one that recurs.
REPO=octopusden/octopus-maven-packages TOKEN=stale GH_RC=1 DRY=false \
  run "refuses a real release when the probe is rejected" 1 "::error title=SHARED_PACKAGES_TOKEN cannot reach octopusden/octopus-maven-packages::"

REPO=octopusden/octopus-maven-packages TOKEN=t DRY=false \
  CHECK='grep -q "argv=api repos/octopusden/octopus-maven-packages .*token=t" probed' \
  run "passes a real release, probing that repository with that token" 0 "Routed publications go to https://maven\.pkg\.github\.com/octopusden/octopus-maven-packages" "::error"

# The probe is a network call on the release path, so its own failure must be distinguishable
# from a missing secret — the two have different fixes and the messages must not blur.
REPO=octopusden/octopus-maven-packages TOKEN=stale GH_RC=1 DRY=false \
  run "names the probe failure, not the missing-secret one" 1 "cannot reach" "is not set"

echo
echo "passed=$pass failed=$fail"
rm -f "$body" "$body.shell"
[ "$fail" = 0 ]
