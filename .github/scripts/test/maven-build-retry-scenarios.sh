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
# The shell is part of the contract, not scenery: `shell: bash` means the body runs under
# `bash --noprofile --norc -eo pipefail`, i.e. with errexit ON. Running it under a plain
# `bash` — as these scenarios first did — silently tests a shell the workflow never uses, and
# every failure path passes for the wrong reason. So the declared shell is carried out of the
# YAML with the body, and an unexpected value stops the suite rather than being ignored.
shell = next((lines[i].strip() for i in range(start, run) if lines[i].strip().startswith("shell:")), None)
if shell not in ("shell: bash", None):
    sys.exit("scenarios only model 'shell: bash'; step declares %r" % shell)
io.open(out, "w", encoding="utf-8").write("\n".join(collected) + "\n")
io.open(out + ".shell", "w", encoding="utf-8").write(shell or "shell: bash (implicit default)")
PY
[ -s "$body" ] || { echo "could not extract the step body"; exit 1; }

# Exactly what a GitHub runner execs for `shell: bash`. Not a detail: errexit is on, and the
# body has to clear it to be able to retry at all.
RUNNER_SHELL=(bash --noprofile --norc -eo pipefail)
echo "step declares: $(cat "$body.shell")"
echo "running it as: ${RUNNER_SHELL[*]} <body>"

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
# One record per attempt: "<exit-code> <log text>", where a literal \n inside the text is a
# newline in the emitted log. Multi-line logs are the whole point of the classification
# scenarios — a stub that emitted only the first line would let them pass on a log they never
# produced, which is how two of them first passed.
printf '%b\n' "${line#* }"
exit "${line%% *}"
STUB
  chmod +x "$dir/bin/mvn"

  ( cd "$dir/ws" && PATH="$dir/bin:$PATH" \
      COUNTER="$dir/counter" ATTEMPTS="$dir/attempts" ARGV="$dir/argv" \
      RUNNER_TEMP="$dir/runner-temp" MVN_PARAMETERS="${MVN_PARAMETERS:-}" \
      "${RUNNER_SHELL[@]}" "$body" ) >"$out" 2>&1
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

# --- a warning is not a failure -----------------------------------------------------------
# Maven WARNs about a transfer and then works around it — a mirror fallback, a 401 on one
# repository — and the build fails on something else entirely. Retrying that costs a second
# build and reports a compile error as a Maven Central outage.
ATTEMPT_SCRIPT='1 [WARNING] Transfer failed for https://repo.maven.apache.org/maven2/foo.pom 401 Unauthorized\n[INFO] Downloaded from central-mirror: .../foo.pom\n[ERROR] COMPILATION ERROR : cannot find symbol' \
run "a transfer WARNING plus a compile error is one build, not two" 1 1 'not retrying' '::warning title=Maven transfer retried::'

ATTEMPT_SCRIPT='1 [WARNING] Could not transfer artifact org.x:y:pom:1.0 from/to central: Connection reset\n[INFO] Downloaded from central-mirror: .../y-1.0.pom\n[ERROR] Tests run: 12, Failures: 2, Errors: 0, Skipped: 0' \
run "a transfer WARNING plus a test failure is one build, not two" 1 1 'not retrying' '::warning title=Maven transfer retried::'

ATTEMPT_SCRIPT='1 [WARNING] Transfer failed for https://repo.maven.apache.org/maven2/foo.pom\n[ERROR] Some other deterministic failure' \
run "a transfer signature only counts on an ERROR or FATAL line" 1 1 'no transfer error on an ERROR or FATAL line' '::warning title=Maven transfer retried::'

# The failure that started this, verbatim in shape: [FATAL], parent POM, one line.
ATTEMPT_SCRIPT='1 [FATAL] Non-resolvable parent POM for org.octopusden.octopus:octopus-test:1.0-SNAPSHOT: org.octopusden.octopus:octopus-parent:pom:2.0.10 (absent): Could not transfer artifact org.octopusden.octopus:octopus-parent:pom:2.0.10 from/to central (https://repo.maven.apache.org/maven2): (bad_record_mac) Received fatal alert: bad_record_mac and '"'"'parent.relativePath'"'"' points at wrong local POM
0 [INFO] BUILD SUCCESS' \
run "the FATAL parent-POM shape from 2026-08-31 is retried" 0 2 '::warning title=Maven transfer retried::'

# Both at once, which a multi-module build produces: one module cannot fetch a dependency,
# another does not compile. The transfer signature IS on an ERROR line here, so the anchor
# alone would retry — and the retry cannot fix the compile error, so the veto decides.
ATTEMPT_SCRIPT='1 [ERROR] Could not transfer artifact org.x:y:pom:1.0 from/to central: Connection reset\n[ERROR] COMPILATION ERROR : cannot find symbol' \
run "a compile error vetoes the retry even beside a real transfer error" 1 1 'not on a transfer' '::warning title=Maven transfer retried::'

ATTEMPT_SCRIPT='1 [ERROR] Could not transfer artifact org.x:y:pom:1.0 from/to central: Connection reset\n[ERROR] Tests run: 8, Failures: 1, Errors: 0, Skipped: 0' \
run "a test failure vetoes it too" 1 1 'not on a transfer' '::warning title=Maven transfer retried::'

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
      MVN_PARAMETERS= "${RUNNER_SHELL[@]}" "$body" ) >"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); echo "ok   an unset RUNNER_TEMP does not fail the build"
  else fail=$((fail+1)); echo "FAIL an unset RUNNER_TEMP does not fail the build (rc=$rc)"; sed 's/^/     | /' "$out"; fi
  rm -rf "$dir"
}
runner_temp_unset

# The one case that tells `rc=${PIPESTATUS[0]}` apart from `rc=$?`: tee fails while mvn
# succeeds. With PIPESTATUS the step reports what MAVEN said, which is the contract — the build
# passed, and losing the log is not a build failure. With `$?` under pipefail it would report
# tee's failure instead, and a green build would go red on an unwritable temp directory.
tee_fails_while_mvn_succeeds() {
  local dir out rc
  dir="$(mktemp -d)"; out="$dir/out.txt"
  mkdir -p "$dir/bin" "$dir/ws" "$dir/ro"
  printf '0 [INFO] BUILD SUCCESS\n' > "$dir/attempts"
  cat > "$dir/bin/mvn" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$COUNTER"
printf '%s\n' "$*" >> "$ARGV"
printf '%b\n' "$(sed -n "${n}p" "$ATTEMPTS")"; exit 0
STUB
  chmod +x "$dir/bin/mvn"; chmod 500 "$dir/ro"
  if : > "$dir/ro/probe" 2>/dev/null; then
    echo "NOTE  \$RUNNER_TEMP could not be made unwritable here (running as root?), so the"
    echo "      PIPESTATUS contract is not exercised by this scenario."
    rm -rf "$dir"; return
  fi
  ( cd "$dir/ws" && PATH="$dir/bin:$PATH" \
      COUNTER="$dir/counter" ATTEMPTS="$dir/attempts" ARGV="$dir/argv" \
      RUNNER_TEMP="$dir/ro" MVN_PARAMETERS= \
      "${RUNNER_SHELL[@]}" "$body" ) >"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); echo "ok   an unwritable log does not fail a build maven passed"
  else fail=$((fail+1)); echo "FAIL an unwritable log does not fail a build maven passed (rc=$rc)"; sed 's/^/     | /' "$out"; fi
  chmod 700 "$dir/ro"; rm -rf "$dir"
}
tee_fails_while_mvn_succeeds

rm -f "$body" "$body.shell"
echo
echo "maven-build-retry scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
