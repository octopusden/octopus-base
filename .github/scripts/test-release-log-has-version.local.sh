#!/usr/bin/env bash
# Local runner for the same cases the CI workflow asserts. Uses a stub `gh` on PATH so no
# network and no real release log are involved; the stub decides what the contents API says.
#
# The script is run under `bash -e` on purpose. That is what GitHub Actions does with a
# `run:` block, and running it any other way would hide the failure this guard was written
# for: the previous inline implementation aborted the whole step on the ordinary 404.
set -uo pipefail
S="$PWD/.github/scripts/release-log-has-version.sh"
stub_dir=$(mktemp -d); trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Stands in for `gh`. Answers only the release-log contents lookup; anything else is a test bug.
#
#   GH_MODE   missing   the module has no file in the log yet — HTTP 404, gh exits 1
#             transport the lookup fails the way a rate limit or 5xx does
#             null      the file exists but the API declined to inline it (over ~1 MB),
#                       so `.content` is JSON null
#             garbage   `.content` is not valid base64
#             ok        LOG_TEXT, base64-encoded
#   LOG_TEXT  the release log the stub serves in `ok` mode
set -u
[ "${1:-}" = "api" ] || { echo "stub gh: unexpected invocation: $*" >&2; exit 99; }
# The lookup must name the log repository and the module, or the guard would be reading
# someone else's log — which fails open and re-registers, silently, forever.
printf '%s\n' "$@" | grep -qx "repos/${EXPECT_REPO}/contents/${EXPECT_MODULE}.txt" || {
    echo "stub gh: unexpected path: $*" >&2; exit 99
}
case "${GH_MODE:-ok}" in
    missing)   echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    transport) echo "gh: HTTP 502" >&2; exit 1 ;;
    null)      echo "null" ;;
    garbage)   echo "this is not base64 %%%" ;;
    # Wrapped across lines like the real contents API, so a script that forgot to strip the
    # newlines before decoding fails here rather than in production.
    *)         printf '%s' "$LOG_TEXT" | base64 | tr -d '\n' | fold -w 16 ;;
esac
STUB
chmod +x "$stub_dir/gh"; export PATH="$stub_dir:$PATH"
export EXPECT_REPO=octopusden/octopus-release-log EXPECT_MODULE=octopus-widget

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1));
  else echo "  FAIL $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi
}
# Run exactly as Actions would: `bash -e`, output captured, exit status appended.
run() { # version -> "<stdout>|<rc>"
  local out rc
  out=$(bash -e "$S" "$EXPECT_REPO" "$EXPECT_MODULE" "$1" 2>/dev/null); rc=$?
  echo "${out}|${rc}"
}

# Exported: the stub is a separate process and reads the log from its environment.
export LOG_TEXT=$'2.0.16\n2.0.15\n2.0.14\n'

# The regression. A module released for the first time has no file in the log; the lookup
# 404s, and the answer must be "not registered", not a dead step.
echo "case: module has no log file yet"
check "false, rc 0" "false|0" "$(GH_MODE=missing run 2.0.1)"

echo "case: version already in the log"
check "true, rc 0" "true|0" "$(run 2.0.15)"

echo "case: version not in the log"
check "false, rc 0" "false|0" "$(run 2.0.17)"

# Fail-open: an unreadable log must register rather than skip.
echo "case: lookup fails (5xx / rate limit)"
check "false, rc 0" "false|0" "$(GH_MODE=transport run 2.0.15)"

echo "case: file too large to inline (content null)"
check "false, rc 0" "false|0" "$(GH_MODE=null run 2.0.15)"

echo "case: content is not decodable"
check "false, rc 0" "false|0" "$(GH_MODE=garbage run 2.0.15)"

# An empty version matches any blank line, so it would read as "already registered" and
# register nothing. This is the one case that must stop the release.
echo "case: empty version"
check "rc 1" "|1" "$(run '')"

# Whole-line match: 2.0.15 is not present in a log that only contains 12.0.15.
echo "case: a longer version is not a match"
check "false, rc 0" "false|0" "$(LOG_TEXT=$'12.0.15\n2.0.16\n' run 2.0.15)"

# ...and neither is a prefix of one.
echo "case: a shorter version is not a match"
check "false, rc 0" "false|0" "$(LOG_TEXT=$'2.0.150\n' run 2.0.15)"

# A log that gained CRLF endings must still match, or the guard would silently never fire.
echo "case: CRLF log"
check "true, rc 0" "true|0" "$(LOG_TEXT=$'2.0.16\r\n2.0.15\r\n' run 2.0.15)"

echo "--- passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
