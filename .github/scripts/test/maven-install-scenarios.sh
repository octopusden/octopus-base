#!/usr/bin/env bash
#
# Scenario tests for the "Install Maven" step, which every job that runs `mvn` in a reusable
# workflow carries a copy of. Without it the job runs whatever Maven the runner image ships, and
# the image changes that under the same label (#246).
#
# These scenarios pin what the copies must keep in common, then EXTRACT one body and execute it
# against a stubbed curl, so there is no second copy here to drift.
#
#   - every common-*.yml that runs mvn has a maven-version input defaulting to DEFAULT_VERSION
#   - every job in it that runs mvn carries exactly one copy, after its JDK and before its first mvn,
#     and runs on a pinned runner label rather than ubuntu-latest
#   - every copy is identical
#   - the archive comes from Maven Central and is put on PATH only when its sha512 matches
#   - a maven-version that is not a version is refused before anything is downloaded
#
# Usage: bash .github/scripts/test/maven-install-scenarios.sh   (from the repo root)

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

STEP = "- name: Install Maven"
DEFAULT_VERSION = "3.10.0"
RUNNER = "ubuntu-24.04"
# A command line that starts Maven. Comments and descriptions mention `mvn` in backticks, which
# this does not match.
MVN = re.compile(r"(^|[\s|;&(\"'])mvn(\s|$)")
JDK = re.compile(r"uses: actions/setup-java@")
# The workflows that run Maven. Pinned, so a new one fails here until it is added on purpose.
EXPECTED = {
    "common-java-maven-build.yml",
    "common-java-maven-release.yml",
    "common-java-maven-sonar.yml",
}

problems, copies, found = [], [], set()

def jobs_of(lines):
    start = next((i for i, l in enumerate(lines) if l.rstrip() == "jobs:"), None)
    if start is None:
        return []
    heads = [i for i in range(start + 1, len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i])]
    return [(lines[h].strip()[:-1], h, heads[k + 1] if k + 1 < len(heads) else len(lines))
            for k, h in enumerate(heads)]

def step_block(lines, at):
    indent = len(lines[at]) - len(lines[at].lstrip())
    end = at + 1
    while end < len(lines):
        l = lines[end]
        if l.strip() and len(l) - len(l.lstrip()) <= indent:
            break
        end += 1
    while end > at and not lines[end - 1].strip():
        end -= 1
    return [l[indent:] for l in lines[at:end]]

def input_default(lines, name):
    at = next((i for i, l in enumerate(lines) if l.strip() == name + ":"), None)
    if at is None:
        return None
    indent = len(lines[at]) - len(lines[at].lstrip())
    for l in lines[at + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) <= indent:
            break
        if l.strip().startswith("default:"):
            return l.split(":", 1)[1].strip().strip("'\"")
    return None

for path in sorted(glob.glob(os.path.join(wf_dir, "common-*.yml"))):
    name = os.path.basename(path)
    lines = io.open(path, encoding="utf-8").read().splitlines()
    code = [i for i, l in enumerate(lines) if not l.lstrip().startswith("#") and MVN.search(l)]
    if not code:
        continue
    found.add(name)
    default = input_default(lines, "maven-version")
    if default != DEFAULT_VERSION:
        problems.append("%s: maven-version input defaults to %r, expected %r" % (name, default, DEFAULT_VERSION))
    for job, first, end in jobs_of(lines):
        mvn_at = [i for i in code if first < i < end]
        if not mvn_at:
            continue
        where = "%s/%s" % (name, job)
        runs_on = next((lines[i].split(":", 1)[1].strip() for i in range(first, end)
                        if lines[i].strip().startswith("runs-on:")), None)
        if runs_on == "${{ inputs.runs-on }}":
            runs_on = input_default(lines, "runs-on")
        if runs_on != RUNNER:
            problems.append("%s: runs Maven on %r, expected %r" % (where, runs_on, RUNNER))
        step_at = [i for i in range(first, end) if lines[i].strip() == STEP]
        if len(step_at) != 1:
            problems.append("%s: runs mvn but has %d copies of the step" % (where, len(step_at)))
            continue
        if step_at[0] > mvn_at[0]:
            problems.append("%s: the step (line %d) comes after mvn (line %d)" % (where, step_at[0] + 1, mvn_at[0] + 1))
        jdk_at = [i for i in range(first, end) if JDK.search(lines[i])]
        if not jdk_at or jdk_at[-1] > step_at[0]:
            problems.append("%s: the step does not come after the job's last setup-java" % where)
        copies.append((where, step_block(lines, step_at[0])))

if found != EXPECTED:
    problems.append("workflows running mvn changed: missing %s, unexpected %s"
                    % (sorted(EXPECTED - found) or "none", sorted(found - EXPECTED) or "none"))
if not copies:
    problems.append("no copy of the step found")
else:
    ref_where, ref = copies[0]
    for where, block in copies[1:]:
        if block != ref:
            problems.append("%s differs from %s" % (where, ref_where))
    stripped = [l.strip() for l in ref]
    if "MAVEN_VERSION: ${{ inputs.maven-version }}" not in stripped:
        problems.append("the step does not take MAVEN_VERSION from the maven-version input")
    if "shell: bash" not in stripped:
        problems.append("the scenarios model 'shell: bash'; the step declares something else")

for p in problems:
    print("FAIL  " + p)
if problems:
    sys.exit(1)
print("PASS  %d copies across %d workflows are identical, after the JDK, ahead of mvn, on %s"
      % (len(copies), len(found), RUNNER))

run = stripped.index("run: |")
indent = len(ref[run]) - len(ref[run].lstrip()) + 2
script = [l[indent:] if l.startswith(" " * indent) else l.strip() for l in ref[run + 1:]]
io.open(out, "w", encoding="utf-8").write("\n".join(script) + "\n")
PY
[ $? = 0 ] && pass=$((pass+1)) || { echo; echo "0 passed, 1 failed"; exit 1; }
[ -s "$body" ] || { echo "FAIL  could not extract the step body"; exit 1; }

# What a GitHub runner execs for `shell: bash`.
RUNNER_SHELL=(bash --noprofile --norc -eo pipefail)
VERSION=9.9.9
URL="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$VERSION/apache-maven-$VERSION-bin.tar.gz"

# The archive the stub curl serves: a Maven whose `mvn -v` says it is the stub.
fixtures="$tmp/fixtures"
mkdir -p "$fixtures/src/apache-maven-$VERSION/bin" "$tmp/bin"
printf '#!/usr/bin/env bash\necho "Apache Maven %s (stub) $*"\n' "$VERSION" > "$fixtures/src/apache-maven-$VERSION/bin/mvn"
chmod +x "$fixtures/src/apache-maven-$VERSION/bin/mvn"
tar -czf "$fixtures/archive.tar.gz" -C "$fixtures/src" "apache-maven-$VERSION"
good_sum="$(python3 -c 'import hashlib,sys; print(hashlib.sha512(open(sys.argv[1],"rb").read()).hexdigest())' "$fixtures/archive.tar.gz")"

# Stub curl: records its argv, then serves $SERVE_<kind> for the archive and its .sha512, or
# fails as curl -f does on a 404 when that variable is empty.
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *.sha512) src="$SERVE_SUM" ;;
  *) src="$SERVE_ARCHIVE" ;;
esac
[ -n "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$src" "$out"
STUB
chmod +x "$tmp/bin/curl"

# run <name> <expected-rc: 0 or nonzero> <check>
#   MAVEN_VERSION, SUM (content of the .sha512; empty = 404), ARCHIVE (1 = served, empty = 404)
run() {
  local name="$1" erc="$2" check="$3"
  local dir="$tmp/case-$pass-$fail" rc ok=true
  mkdir -p "$dir/rt" "$dir/ws"
  : > "$dir/github_path"; : > "$dir/curl.log"
  local sum_file=""
  if [ -n "${SUM-}" ]; then printf '%s' "$SUM" > "$dir/sum"; sum_file="$dir/sum"; fi
  ( cd "$dir/ws" && PATH="$tmp/bin:$PATH" MAVEN_VERSION="$MAVEN_VERSION" \
      RUNNER_TEMP="$dir/rt" GITHUB_PATH="$dir/github_path" CURL_LOG="$dir/curl.log" \
      SERVE_SUM="$sum_file" SERVE_ARCHIVE="${ARCHIVE:+$fixtures/archive.tar.gz}" \
      "${RUNNER_SHELL[@]}" "$body" ) >"$dir/out.txt" 2>&1
  rc=$?
  if [ "$erc" = 0 ]; then [ "$rc" = 0 ] || { ok=false; echo "  rc=$rc, expected 0"; }
  else [ "$rc" != 0 ] || { ok=false; echo "  rc=0, expected a failure"; }; fi
  ( cd "$dir" && eval "$check" ) || { ok=false; echo "  check failed: $check"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1))
    sed 's/^/    | out: /' "$dir/out.txt"; sed 's/^/    | path: /' "$dir/github_path"; sed 's/^/    | curl: /' "$dir/curl.log"
  fi
}

echo "-- the body, executed ------------------------------------------------------"
bin_dir='rt/maven-'"$VERSION"'/apache-maven-'"$VERSION"'/bin'

# One run, every property of the happy path; each failed assertion names itself. The retry flag
# is here because without --retry-all-errors curl retries only timeouts and HTTP 408/429/5xx, not
# the TLS and connection-reset failures Central has actually produced (TD-002).
MAVEN_VERSION=$VERSION SUM="$good_sum" ARCHIVE=1 \
run "a matching checksum installs that Maven from Central, first on PATH, and prints its version" 0 \
  'rc=0
   [ "$(cat github_path)" = "$PWD/'"$bin_dir"'" ] || { echo "  not exactly that Maven on PATH"; rc=1; }
   grep -q "^Apache Maven '"$VERSION"' (stub) -v$" out.txt || { echo "  installed mvn -v not in the log"; rc=1; }
   grep -qF -- "'"$URL"'" curl.log && grep -qF -- "'"$URL"'.sha512" curl.log || { echo "  not downloaded from Maven Central"; rc=1; }
   [ "$(grep -c -- "--retry-all-errors" curl.log)" = 2 ] || { echo "  a download does not retry on connection errors"; rc=1; }
   exit "$rc"'
MAVEN_VERSION=$VERSION SUM="$good_sum  apache-maven-$VERSION-bin.tar.gz" ARCHIVE=1 \
run "a checksum file that also names the archive is accepted" 0 \
  '[ -s github_path ]'

MAVEN_VERSION=$VERSION SUM="$(printf '0%.0s' $(seq 128))" ARCHIVE=1 \
run "a checksum mismatch fails and puts nothing on PATH" 1 \
  '[ ! -s github_path ] && ! grep -q "(stub)" out.txt && grep -q "::error title=Maven checksum mismatch::" out.txt'
MAVEN_VERSION=$VERSION SUM="" ARCHIVE=1 \
run "a missing checksum file fails and puts nothing on PATH" 1 \
  '[ ! -s github_path ]'
MAVEN_VERSION=$VERSION SUM=" " ARCHIVE=1 \
run "an empty checksum file fails and puts nothing on PATH" 1 \
  '[ ! -s github_path ] && grep -q "::error title=Maven checksum mismatch::" out.txt'
MAVEN_VERSION=$VERSION SUM="$good_sum" ARCHIVE='' \
run "a missing archive fails and puts nothing on PATH" 1 \
  '[ ! -s github_path ]'

for bad in '' 'latest' '3.9' '4.0.0-rc-7' '../../x' '3.9.16/../../evil' '3.9.16 -o /tmp/x'; do
  MAVEN_VERSION="$bad" SUM="$good_sum" ARCHIVE=1 \
  run "maven-version '$bad' is refused before any download" 1 \
    '[ ! -s curl.log ] && [ ! -s github_path ] && grep -q "::error title=Invalid maven-version::" out.txt'
done

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
