#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/inspect-publication-set.py.
#
# The input is a local Maven repository, so the fixtures are directory trees written here — no
# Gradle needed. That is what makes the refusals testable at all: they depend on the layout
# (`<group path>/<artifact>/<version>/<file>`) and on what is inside the archives.
#
# This guard had no tests before the version refusal was added to it, which is the wrong way
# round: its failure mode is to wave something through to an immutable public repository.
#
# Usage: bash .github/scripts/test/publication-set-scenarios.sh   (from the repo root)

# shellcheck disable=SC2016,SC2034
# The SETUP values are single-quoted on purpose: they are fixture code, eval'd inside run()
# once $repo exists. $G is referenced from inside them, which shellcheck cannot see.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../inspect-publication-set.py"
[ -f "$SCRIPT" ] || { echo "inspect-publication-set.py not found"; exit 1; }

pass=0; fail=0

# jar <repo> <group-path> <artifact> <version> <filename> [entry-inside]
jar() {
  local dir="$1/$2/$3/$4"; mkdir -p "$dir"
  local target="$dir/$5"
  if [ -n "${6:-}" ]; then
    local stage; stage="$(mktemp -d)"; mkdir -p "$stage/$(dirname "$6")"
    echo x > "$stage/$6"
    ( cd "$stage" && zip -q -r "$target" . )
    rm -rf "$stage"
  else
    # A minimal real zip, so the Spring Boot probe reads a valid archive rather than skipping it.
    local stage; stage="$(mktemp -d)"; echo x > "$stage/a.txt"
    ( cd "$stage" && zip -q -r "$target" . )
    rm -rf "$stage"
  fi
}

# pad <path> <mb> — grow a file past the size limit
pad() { local f="$1"; local mb="$2"; dd if=/dev/zero bs=1048576 count="$mb" >> "$f" 2>/dev/null; }

# run <name> <expected-rc> <must-match> [<must-not-match>]  — fixture built by $SETUP
run() {
  local name="$1" erc="$2" want="$3" nowant="${4:-}"
  local repo; repo="$(mktemp -d)"
  eval "${SETUP}"
  local out; out="$(mktemp)"
  env BUILD_VERSION="${VERSION-2.0.105}" \
      FAT_JAR_ALLOWLIST="${ALLOWLIST:-}" \
      MAX_ARTIFACT_MB="${MAX_MB:-8}" \
      python3 "$SCRIPT" "$repo" >"$out" 2>&1
  local rc=$? ok=true
  [ "$rc" = "$erc" ] || { ok=false; echo "  rc=$rc expected=$erc"; }
  [ -n "$want" ] && ! grep -qE "$want" "$out" && { ok=false; echo "  missing: $want"; }
  [ -n "$nowant" ] && grep -qE "$nowant" "$out" && { ok=false; echo "  unexpected: $nowant"; }
  if $ok; then echo "PASS  $name"; pass=$((pass+1)); else
    echo "FAIL  $name"; fail=$((fail+1)); sed 's/^/    | /' "$out"
  fi
  rm -rf "$repo" "$out"
}

G=org/octopusden/octopus

echo "-- a release publishes exactly one version --------------------------------"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar' \
  run "accepts a publication at the release version" 0 "Publication set is fit"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' \
  run "refuses Gradle's unspecified version" 1 "carries version 'unspecified'"
SETUP='jar "$repo" "$G" client 0.0.0 client-0.0.0.jar' \
  run "refuses any other version" 1 "carries version '0.0.0'"
SETUP='jar "$repo" "$G" client 2.0.105 client-2.0.105.jar
jar "$repo" "$G" legacy unspecified legacy-unspecified.jar' \
  run "refuses when only ONE of several publications is adrift" 1 "legacy"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' VERSION='' \
  run "checks nothing when no release version is known" 0 "Publication set is fit" "carries version"
SETUP='jar "$repo" "$G" client unspecified client-unspecified.jar' \
  run "says which release version it expected" 1 "This release is 2.0.105"

echo "-- artifacts unfit for Central (pre-existing rules) -----------------------"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' \
  run "refuses a shadow/uber artifact" 1 "shadow/uber"
SETUP='jar "$repo" "$G" automation 2.0.105 automation-2.0.105-all.jar' ALLOWLIST=automation \
  run "accepts an allowlisted shadow artifact" 0 "Explicitly allowed: automation"
SETUP='jar "$repo" "$G" app 2.0.105 app-2.0.105.jar BOOT-INF/classes/x.class' \
  run "refuses a Spring Boot executable jar" 1 "BOOT-INF"
SETUP='jar "$repo" "$G" big 2.0.105 big-2.0.105.jar; pad "$repo/$G/big/2.0.105/big-2.0.105.jar" 9' \
  run "refuses an oversized artifact" 1 "exceeds 8 MB"
SETUP='jar "$repo" "$G" big 2.0.105 big-2.0.105.jar; pad "$repo/$G/big/2.0.105/big-2.0.105.jar" 9' MAX_MB=16 \
  run "accepts it under a raised limit" 0 "Publication set is fit"

echo "-- the version refusal comes first ---------------------------------------"
# Both defects at once: the version is the one to report, since it means the build is wrong
# rather than the artifact being unsuitable.
SETUP='jar "$repo" "$G" automation unspecified automation-unspecified-all.jar' \
  run "reports the version, not the shadow classifier" 1 "carries version 'unspecified'" "shadow/uber"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
