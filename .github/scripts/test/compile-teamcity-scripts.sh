#!/usr/bin/env bash
# Compiles every TeamCity .main.kts with the exact Kotlin compiler version the
# agents use, on this runner's JDK.
#
# Why this exists: these scripts are never built by Gradle, so nothing else in CI
# type-checks them — a broken one is only discovered by a failing release. Two
# real breakages motivated this check: a smart-cast that only the pinned compiler
# rejects, and an HTTP library that JDK 17+ forbids at runtime (the agents' JDK is
# not fixed, so the script must work on old and new alike).
#
# Each script is invoked with no arguments and must answer with its usage line.
# Reaching that line proves compilation succeeded and no release logic ran.
set -euo pipefail

KOTLIN_VERSION="${KOTLIN_VERSION:-1.5.32}"
ROOT="${1:-.}"
SCRIPT_DIR="$ROOT/teamcity/scripts"

if [ ! -d "$SCRIPT_DIR" ]; then
  echo "No $SCRIPT_DIR directory — nothing to compile." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# KOTLINC_HOME lets a caller reuse an already-unpacked compiler (cache step, or a
# local run) instead of downloading it again.
if [ -n "${KOTLINC_HOME:-}" ] && [ -f "$KOTLINC_HOME/bin/kotlinc" ]; then
  echo "Using Kotlin compiler from $KOTLINC_HOME"
  KOTLINC="$KOTLINC_HOME/bin/kotlinc"
else
  echo "Fetching Kotlin compiler $KOTLIN_VERSION"
  curl -sSL --retry 3 --retry-delay 5 --max-time 300 -o "$WORK/kotlin.zip" \
    "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VERSION}/kotlin-compiler-${KOTLIN_VERSION}.zip"
  unzip -q "$WORK/kotlin.zip" -d "$WORK"
  KOTLINC="$WORK/kotlinc/bin/kotlinc"
fi
chmod +x "$KOTLINC" 2>/dev/null || true
java -version 2>&1 | head -1

status=0
found=0
while IFS= read -r script; do
  found=$((found + 1))
  echo "--- $script"
  out="$WORK/out.txt"
  # A usage-rejecting script exits non-zero by design, so the exit code alone
  # cannot tell a compile failure from the expected refusal — inspect the output.
  set +e
  "$KOTLINC" -script "$script" >"$out" 2>&1
  set -e
  if grep -qE '(^|:)error:' "$out"; then
    echo "    FAIL: did not compile"
    sed 's/^/      /' "$out"
    status=1
    continue
  fi
  if ! grep -q 'Arguments:' "$out"; then
    echo "    FAIL: compiled but never reached its argument check"
    sed 's/^/      /' "$out"
    status=1
    continue
  fi
  echo "    OK: compiles and rejects empty arguments"
done < <(find "$SCRIPT_DIR" -type f -name '*.main.kts' | sort)

if [ "$found" -eq 0 ]; then
  echo "No .main.kts found under $SCRIPT_DIR — the check would pass vacuously." >&2
  exit 1
fi

exit "$status"
