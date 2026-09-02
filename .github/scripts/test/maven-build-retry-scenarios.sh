#!/usr/bin/env bash
#
# Scenario tests for the retry around `mvn` in .github/workflows/common-java-maven-build.yml.
#
# The script under test is not a file: it is the `run:` body of the "Maven build" step. These
# scenarios EXTRACT that body from the workflow and execute it, so there is no second copy of
# the logic to drift — edit the workflow and these scenarios follow, or fail.
#
# `mvn` is replaced by a stub whose per-attempt behaviour comes from ATTEMPT_SCRIPT: one line
# per attempt, `<exit-code> <log line>`. That is what makes the interesting cases reachable
# without a build.
#
# The property under test is a pair, and both halves matter:
#   - a transfer failure costs a second attempt (and says so), because one corrupted packet
#     must not redden a required check;
#   - anything else costs exactly one, because retrying a compile error or a failing test
#     buys nothing and hides the cause.
#
# Usage: bash .github/scripts/test/maven-build-retry-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../../.."
workflow="$root/.github/workflows/common-java-maven-build.yml"
[ -f "$workflow" ] || { echo "workflow not found: $workflow"; exit 1; }

pass=0; fail=0

# The step body, lifted out of the YAML by step name. Guards against the extraction silently
# matching nothing, which would make every scenario pass against an empty script.
body="$(mktemp)"
python3 - "$workflow" "$body" <<'PY'
import io, sys
workflow, out = sys.argv[1], sys.argv[2]
lines = io.open(workflow, encoding="utf-8").read().splitlines()
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Maven build")
except StopIteration:
    sys.exit("step 'Maven build' not found")
run = next((i for i in range(start, len(lines)) if lines[i].strip() == "run: |"), None)
if run is None:
    sys.exit("step 'Maven build' has no 'run: |' body")
indent = len(lines[run]) - len(lines[run].lstrip()) + 2
collected = []
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(" " * indent):
        break
    collected.append(line[indent:] if len(line) > indent else line.strip())
if not any(l.strip().startswith("mvn ") for l in collected):
    sys.exit("extracted body does not invoke mvn; extraction is wrong")
io.open(out, "w", encoding="utf-8").write("\n".join(collected) + "\n")
PY
[ -s "$body" ] || { echo "could not extract the step body"; exit 1; }

# run <name> <expected-rc> <expected-mvn-attempts> <must-match> [<must-not-match>]
#   ATTEMPT_SCRIPT  one line per attempt: "<exit-code> <text the stub prints>"
run() {
  local name="$1" erc="$2" eattempts="$3" want="$4" nowant="${5:-}"
  local dir out rc attempts ok=true
  dir="$(mktemp -d)"; out="$dir/out.txt"

  mkdir -p "$dir/bin" "$dir/ws" "$dir/runner-temp"
  printf '%s\n' "${ATTEMPT_SCRIPT}" > "$dir/attempts"
  cat > "$dir/bin/mvn" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNTER"
printf '%s\n' "$*" >> "$ARGV"
line="$(sed -n "${n}p" "$ATTEMPTS")"
[ -n "$line" ] || { echo "stub mvn: no behaviour defined for attempt $n" >&2; exit 99; }
printf '%s\n' "${line#* }"
exit "${line%% *}"
STUB
  chmod +x "$dir/bin/mvn"

  ( cd "$dir/ws" && PATH="$dir/bin:$PATH" \
      COUNTER="$dir/counter" ATTEMPTS="$dir/attempts" ARGV="$dir/argv" \
      RUNNER_TEMP="$dir/runner-temp" MVN_PARAMETERS="${MVN_PARAMETERS:-}" \
      bash "$body" ) >"$out" 2>&1
  rc=$?
  attempts="$(cat "$dir/counter" 2>/dev/null || echo 0)"

  [ "$rc" = "$erc" ] || { ok=false; echo "  rc: want $erc, got $rc"; }
  [ "$attempts" = "$eattempts" ] || { ok=false; echo "  mvn attempts: want $eattempts, got $attempts"; }
  grep -qE "$want" "$out" || { ok=false; echo "  missing: $want"; }
  if [ -n "$nowant" ] && grep -qE "$nowant" "$out"; then ok=false; echo "  unexpected: $nowant"; fi
  if [ -n "${EXPECT_ARGV:-}" ] && ! grep -qE "$EXPECT_ARGV" "$dir/argv"; then
    ok=false; echo "  mvn argv missing: $EXPECT_ARGV"; echo "  argv was: $(cat "$dir/argv" 2>/dev/null)"
  fi
  if [ "${EXPECT_LOG_IN_RUNNER_TEMP:-}" = "1" ]; then
    [ -s "$dir/runner-temp/maven-build.log" ] || { ok=false; echo "  no log under RUNNER_TEMP"; }
    if find "$dir/ws" -type f | grep -q .; then
      ok=false; echo "  working directory is not clean: $(find "$dir/ws" -type f | tr '\n' ' ')"
    fi
  fi

  if $ok; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/     | /' "$out"; fi
  rm -rf "$dir"
}

# --- the failure that motivated the change -----------------------------------------------
ATTEMPT_SCRIPT='1 [ERROR] Could not transfer artifact org.octopusden.octopus:octopus-parent:pom:2.0.10 from/to central: (bad_record_mac) Received fatal alert: bad_record_mac
0 [INFO] BUILD SUCCESS' \
run "the observed bad_record_mac is retried, and the retry succeeds" 0 2 '::warning title=Maven transfer retried::'

ATTEMPT_SCRIPT='1 [ERROR] Could not transfer artifact org.octopusden:x:pom:1.0 from/to central: (bad_record_mac) Received fatal alert: bad_record_mac
1 [ERROR] Could not transfer artifact org.octopusden:x:pom:1.0 from/to central: (bad_record_mac) Received fatal alert: bad_record_mac' \
run "a transfer error on every attempt fails the step, as an outage" 1 2 '::error title=Maven transfer failed on every attempt::'

# --- the half that must NOT retry ---------------------------------------------------------
ATTEMPT_SCRIPT='1 [ERROR] COMPILATION ERROR : cannot find symbol' \
run "a compile error costs one build, not two" 1 1 'not retrying' '::warning title=Maven transfer retried::'

ATTEMPT_SCRIPT='1 [ERROR] Tests run: 3, Failures: 1, Errors: 0, Skipped: 0' \
run "a failing test is not a transfer error" 1 1 'not retrying' '::warning'

ATTEMPT_SCRIPT='1 [ERROR] Could not find artifact org.octopusden:missing:pom:9.9.9 in central' \
run "a missing artifact is deterministic and is not retried" 1 1 'not retrying' '::warning'

ATTEMPT_SCRIPT='0 [INFO] BUILD SUCCESS' \
run "a passing build runs mvn exactly once and warns about nothing" 0 1 'BUILD SUCCESS' '::warning|::error'

# --- the other transfer signatures --------------------------------------------------------
for sig in 'Connection reset' 'Connection timed out' 'Read timed out' \
           'Premature end of Content-Length delimited message body' \
           'org.apache.http.NoHttpResponseException: repo.maven.apache.org failed to respond' \
           'javax.net.ssl.SSLException: Connection reset' \
           'Transfer failed for https://repo.maven.apache.org/maven2/x.pom' \
           'status code: 503'; do
  ATTEMPT_SCRIPT="1 [ERROR] $sig
0 [INFO] BUILD SUCCESS" \
  run "retried: $sig" 0 2 '::warning title=Maven transfer retried::'
done

# --- the mechanics that are easy to break silently ----------------------------------------
ATTEMPT_SCRIPT='2 [ERROR] COMPILATION ERROR : cannot find symbol' \
run "maven's exit code survives the pipe to tee" 2 1 'not retrying'

MVN_PARAMETERS='-DskipTests -Dfoo=bar' ATTEMPT_SCRIPT='0 [INFO] BUILD SUCCESS' \
EXPECT_ARGV='^--batch-mode --update-snapshots package -DskipTests -Dfoo=bar$' \
run "consumer parameters reach mvn as separate words, after package" 0 1 'BUILD SUCCESS'

ATTEMPT_SCRIPT='0 [INFO] BUILD SUCCESS' EXPECT_ARGV='^--batch-mode --update-snapshots package$' \
run "with no parameters the argv is exactly batch-mode, update-snapshots, package" 0 1 'BUILD SUCCESS'

MVN_PARAMETERS='; echo INJECTED' ATTEMPT_SCRIPT='0 [INFO] BUILD SUCCESS' \
run "parameters cannot smuggle shell syntax" 0 1 'BUILD SUCCESS' 'INJECTED'

# The log is written where the runner cleans up, not into the checkout, where it would end
# up in a build artifact or a dirty tree.
ATTEMPT_SCRIPT='0 [INFO] BUILD SUCCESS' EXPECT_LOG_IN_RUNNER_TEMP=1 \
run "the log lands under RUNNER_TEMP and leaves the checkout clean" 0 1 'BUILD SUCCESS'

# RUNNER_TEMP is set on every GitHub runner, but the body must not depend on it: an unset
# value used to be an error under `set -u`, which would fail the build for no reason.
runner_temp_unset() {
  local dir out rc
  dir="$(mktemp -d)"; out="$dir/out.txt"
  mkdir -p "$dir/bin" "$dir/ws"
  printf '0 [INFO] BUILD SUCCESS\n' > "$dir/attempts"
  sed 's|__NOTHING__||' "$dir/bin/mvn" 2>/dev/null || true
  cat > "$dir/bin/mvn" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNTER"
printf '%s\n' "$*" >> "$ARGV"
line="$(sed -n "${n}p" "$ATTEMPTS")"
printf '%s\n' "${line#* }"
exit "${line%% *}"
STUB
  chmod +x "$dir/bin/mvn"
  ( cd "$dir/ws" && PATH="$dir/bin:$PATH" env -u RUNNER_TEMP \
      COUNTER="$dir/counter" ATTEMPTS="$dir/attempts" ARGV="$dir/argv" \
      MVN_PARAMETERS= bash "$body" ) >"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); echo "ok   an unset RUNNER_TEMP does not fail the build"
  else fail=$((fail+1)); echo "FAIL an unset RUNNER_TEMP does not fail the build (rc=$rc)"; sed 's/^/     | /' "$out"; fi
  rm -rf "$dir"
}
runner_temp_unset

rm -f "$body"
echo
echo "maven-build-retry scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
