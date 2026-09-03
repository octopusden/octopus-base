#!/usr/bin/env bash
#
# Scenario tests for .github/scripts/recover-release.sh — the reconciler an operator runs after a
# release published to Maven Central and died before recording anything (octopus-base#189).
#
# What these pin, in order of what it costs to get wrong:
#
#   * a PLAN writes NOTHING, and the fixture logs every call, so that is asserted against the
#     calls rather than against a message claiming it;
#   * the exit code is non-zero while any ledger is unfinished — 2.0.15 was recovered by hand with
#     the tag and release made and the log entry forgotten for four days, and nothing was red;
#   * the release-log write inserts ONE line and leaves every other byte alone. The fixtures are
#     the real files from octopusden/octopus-release-log, adjacent duplicates included: four module
#     files carry them, so a reconciler that refuses them refuses the canary itself;
#   * the log is written only after the tag and the release are confirmed, because it is the only
#     ledger with a consumer outside this repository.
#
# Three guards in the script are deliberately NOT pinned here: the `mktemp -d` check, the
# line-count check in build_content, and the emptiness check on the encoded payload. All three
# defend against local I/O failing — a full disk, an unwritable scratch directory — and none can be
# produced from outside without a fault-injection knob in production code. A `TMPDIR` seam does not
# work either: on macOS `mktemp -d` ignores an unusable TMPDIR and falls back, so such a test would
# pass on Linux and mean nothing here. They stay as defence in depth, unpinned and said so.
#
# Usage: bash .github/scripts/test/recover-release-scenarios.sh   (from the repo root)

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
script="$scripts/recover-release.sh"
fixtures="$here/recover-release/fixtures"
[ -f "$script" ] || { echo "recover-release.sh not found"; exit 1; }

BUILT="$(printf 'a%.0s' {1..40})"
COORD="org.octopusden.octopus-test:octopus-test"
pass=0; fail=0

# run <name> <expected-rc> [<must-match>] [<forbidden-calls>] [<required-calls>] [<expected-written-file>]
run() {
  local name="$1" erc="$2" want="${3:-}" forbid="${4:-}" require="${5:-}" written="${6:-}" ok=true
  local tmp; tmp="$(mktemp -d)"
  local out="$tmp/out" rc=0
  CALL_LOG="$tmp/calls"; : > "$CALL_LOG"
  (
    export CALL_LOG PATH="$here/recover-release:$PATH"
    export BUILT RELEASE_LOG_REPO=octopusden/octopus-release-log
    bash "$script" ${ARGS:-octopusden/octopus-test 2.0.15 "$BUILT" "$COORD"} ${APPLY_FLAG:-}
  ) >"$out" 2>&1 || rc=$?

  [ "$rc" = "$erc" ] || { ok=false; echo "  expected rc $erc, got $rc"; }
  [ -z "$want" ] || grep -q "$want" "$out" || { ok=false; echo "  output did not mention: $want"; }
  if [ -n "$forbid" ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      grep -qx "$w" "$CALL_LOG" && { ok=false; echo "  performed a forbidden call: $w"; }
    done <<<"${forbid//,/$'\n'}"
  fi
  if [ -n "$require" ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      grep -qx "$w" "$CALL_LOG" || { ok=false; echo "  did not perform: $w"; }
    done <<<"${require//,/$'\n'}"
  fi
  if [ -n "$written" ]; then
    if [ -f "$CALL_LOG.state.written" ]; then
      diff -u "$written" "$CALL_LOG.state.written" > "$tmp/diff" 2>&1 \
        || { ok=false; echo "  the bytes written are not the expected file:"; sed 's/^/    /' "$tmp/diff" | head -20; }
    else
      ok=false; echo "  nothing was written"
    fi
  fi

  if $ok; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/    | /' "$out" | tail -12; sed 's/^/    calls| /' "$CALL_LOG"; fi
  rm -rf "$tmp" "$CALL_LOG".state* 2>/dev/null
}

base() {
  export AUTH=ok COMMIT_EXISTS=yes COMPARE=behind
  export TAG_STATE=absent REL_STATE=absent REF_CREATE=ok PUT=ok
  export LOG_FILE="$fixtures/octopus-test.txt"
  # Exported empty rather than unset: a case below assigns to these by name, and an assignment to
  # a variable that is not already exported would never reach the fixture.
  export LOG_MISSING="" LOG_UNREADABLE="" LOG_BASE64_TRUNCATED="" LOG_FILE_2="" CONFIRM_FAILS=""
  export ABSENT_ARTIFACTS="" UNKNOWN_ARTIFACTS=""
  APPLY_FLAG=""; ARGS=""
}

echo "-- arguments are validated before anything reaches an API ------------------"
# Every one of these values is interpolated into a request path.
base; ARGS="not-a-repo 2.0.15 $BUILT $COORD"
run "a malformed repository is refused" 1 "not owner/repo" "auth-status,commit-lookup,log-read"
base; ARGS="octopusden/octopus-test 2.0 $BUILT $COORD"
run "a version that is not X.Y.Z is refused, because the log is compared as three numbers" 1 \
  "not an X.Y.Z version" "auth-status,commit-lookup,log-read"
base; ARGS="octopusden/octopus-test 2.0.15 abc123 $COORD"
run "a short commit is refused rather than resolved" 1 "not a full 40-character" "commit-lookup"
base; ARGS="octopusden/octopus-test 2.0.15 $BUILT not-a-coordinate"
run "a malformed coordinate is refused" 1 "not a group:artifact" "commit-lookup"
base; ARGS="octopusden/octopus-test 2.0.15 $BUILT $COORD --wat"
run "an unknown option is refused rather than ignored" 1 "not an option"

echo "-- the credential -------------------------------------------------------"
base; AUTH=fail
run "an unauthenticated gh stops the run" 1 "gh auth login" "commit-lookup,log-read"
# Without `workflow` scope GitHub refuses to create a tag on a commit that touches a workflow file
# (#180) — and it refuses it AFTER the other ledgers would have been written.
base; AUTH=no-workflow-scope
run "a token without workflow scope is refused up front, naming #180" 1 "gh auth refresh -s workflow" \
  "log-read,ref-create"
base; AUTH=fine-grained
run "a fine-grained token cannot report scopes, so it is allowed with a note" 0 "does not report scopes"

echo "-- Maven Central decides whether this is a #189 at all ---------------------"
base; ABSENT_ARTIFACTS="octopus-test"
run "nothing published: say so and send the operator back to a re-run" 1 "Re-run the release instead" \
  "ref-create,log-put"
base; UNKNOWN_ARTIFACTS="octopus-test"
run "Central did not answer: refuse rather than guess" 1 "did not answer" "ref-create,log-put"
# A partial publish can be neither recovered nor re-run: Central refuses the coordinates that exist.
base; ARGS="octopusden/octopus-test 2.0.15 $BUILT ${COORD},org.octopusden.octopus-test:other"
ABSENT_ARTIFACTS="other"
run "a partly published version refuses both paths and explains why" 1 "only partly published" \
  "ref-create,log-put"

echo "-- the commit ------------------------------------------------------------"
base; COMMIT_EXISTS=no
run "a commit that does not exist stops the run" 1 "has no commit" "ref-create,log-put"
# Reported, never gated: a squash-merged branch that was deleted leaves a commit no branch reaches.
base; COMPARE=ahead
run "a commit no branch reaches is reported, not refused" 0 "you are attesting it"
base; COMPARE=fail
run "a comparison that fails does not stop the plan" 0 "could not be compared"

echo "-- a plan writes nothing -------------------------------------------------"
base
run "a plan reads every fact and writes nothing" 0 "Plan only" \
  "ref-create,release-create,release-publish,log-put" "commit-lookup,ref-lookup,release-json,log-read"
# The tag is asked for as a REF first: `/commits/<name>` also resolves a branch or a raw sha, so a
# branch called v2.0.15 would otherwise read as the tag being present, and the log entry would be
# written for a version that has no tag at all.
base; TAG_STATE=at-built
run "an existing tag is confirmed as a ref before it is resolved" 0 "at the commit" "" \
  "ref-lookup,tag-resolve"
base; TAG_STATE=absent
run "a branch sharing the tag's name is not mistaken for the tag" 0 "tag            absent" "tag-resolve"
base; TAG_STATE=at-built REL_STATE=published LOG_FILE="$fixtures/octopus-test-with-2.0.15.txt"
run "a plan over a complete state says there is nothing to do" 0 "leave it" \
  "ref-create,release-create,log-put"
# The state the reconciler exists for: the log has already moved past the version being recovered.
base
run "a plan names the position the entry will take" 0 "at the end, after 2.2.19"
base
run "a plan reports the duplicates it will leave alone" 0 "adjacent duplicate"
# The middle-insert case on the real file: 2.2.30 lands between the duplicated 2.2.36 pair and
# 2.2.28, and the pair above it must survive untouched.
base; ARGS="octopusden/octopus-test 2.2.30 $BUILT $COORD"
run "a plan names a middle position" 0 "between 2.2.36 and 2.2.28"

echo "-- the tag and the release -----------------------------------------------"
base; TAG_STATE=at-other
run "a tag standing at another commit stops everything, moving nothing" 1 "stands at another commit" \
  "ref-create,release-create,log-put"
base; REL_STATE=error
run "a release lookup that fails for a reason other than 404 stops the run" 1 "Refusing to act on unverified state" \
  "ref-create,log-put"
base; APPLY_FLAG="--apply"; REL_STATE=draft; TAG_STATE=at-built
run "a stranded draft is published rather than reported as done" 0 "publish the draft" "" "release-publish"

echo "-- apply: the order is the point -----------------------------------------"
base; APPLY_FLAG="--apply"
run "a full recovery writes all three, in order" 0 "written now" "" \
  "ref-create,graphql,release-create,log-put"
# The log is the only ledger with a consumer outside this repository, and the release path never
# shows that consumer a version whose tag and release are not already there.
base; APPLY_FLAG="--apply"; REF_CREATE=refused
run "a tag that cannot be created leaves the log untouched and exits non-zero" 1 "not attempted" "log-put"
# The gate that has to hold when tag-and-release.sh itself SUCCEEDS: its own release lookups sit
# inside `if` conditions, where errexit is suppressed, so a failed lookup there can leave a draft
# unpublished and still exit 0. The release log is the only ledger with a consumer outside these
# repositories, and it must not learn about a version whose release is not confirmed.
base; APPLY_FLAG="--apply"; CONFIRM_FAILS=error
run "a release that cannot be confirmed after the write leaves the log untouched" 1 "not attempted" "log-put"
base; APPLY_FLAG="--apply"; CONFIRM_FAILS=draft
run "a release still a draft after the write leaves the log untouched" 1 "not attempted" "log-put"
base; APPLY_FLAG="--apply"; CONFIRM_FAILS=othertag
run "a release attached to another tag leaves the log untouched" 1 "not attempted" "log-put"

echo "-- apply: the release-log write ------------------------------------------"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
run "the entry is appended, one line, every other byte unchanged" 0 "written now" "" \
  "log-put,log-put-with-sha,log-put-message-ok,log-put-committer-ok,log-put-author-ok,log-put-branch-ok" \
  "$fixtures/expected-octopus-test-2.0.15.txt"
# The insertion that matters most: into the middle of a file that already carries duplicates.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
ARGS="octopusden/octopus-test 2.2.30 $BUILT $COORD"
run "a middle insertion leaves the duplicate pair above it intact" 0 "written now" "" "log-put" \
  "$fixtures/expected-octopus-test-2.2.30.txt"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published LOG_MISSING=1
run "a module with no file yet is created, without a sha" 0 "create octopus-test.txt" \
  "log-put-with-sha" "log-put,log-put-without-sha"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/octopus-test-with-2.0.15.txt"
run "a version already recorded is left alone" 0 "leave it" "log-put"
# Four real files carry adjacent duplicates. Refusing them would refuse the canary itself.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/octopus-test-2.0.15-twice.txt"
run "a version recorded twice is left alone and warned about, not repaired" 0 "present 2 times" "log-put"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/octopus-versions-api.txt"; ARGS="octopusden/octopus-versions-api 2.0.10 $BUILT $COORD"
run "a one-line file gains the newer version on top" 0 "as the first line" "" "log-put" \
  "$fixtures/expected-versions-api-2.0.10.txt"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/octopus-versions-api.txt"; ARGS="octopusden/octopus-versions-api 2.0.8 $BUILT $COORD"
run "a version older than every line is appended at the end" 0 "at the end" "" "log-put" \
  "$fixtures/expected-versions-api-2.0.8.txt"
# A file whose last byte is not a newline: appending to it must not join two versions into one.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/no-trailing-newline.txt"; ARGS="octopusden/octopus-test 2.0.15 $BUILT $COORD"
run "a file without a trailing newline is rewritten with one" 0 "" "" "log-put" \
  "$fixtures/expected-no-trailing-newline.txt"

echo "-- apply: the file this must not touch -----------------------------------"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/out-of-order.txt"
run "an out-of-order file is refused, not silently repaired" 1 "which is not descending" "log-put"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published
LOG_FILE="$fixtures/malformed-line.txt"
run "a line that is not a version is refused, naming it" 1 "line 2 is .not-a-version., not an X.Y.Z" "log-put"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; LOG_UNREADABLE=1
run "a log that cannot be read stops the write" 1 "could not be read" "log-put"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; LOG_BASE64_TRUNCATED=1
run "a payload that is not decodable base64 stops the write" 1 "could not be read" "log-put"

echo "-- apply: compare-and-swap ------------------------------------------------"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/octopus-test-newer.txt"
run "a conflict is re-read and retried once against what is there now" 0 "written now" "" "log-read,log-put" \
  "$fixtures/expected-octopus-test-newer-2.0.15.txt"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/octopus-test-with-2.0.15.txt"
run "a conflict where the version has since landed is adopted, not written again" 0 "someone else" ""
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-twice
LOG_FILE_2="$fixtures/octopus-test-newer.txt"
run "a file that keeps changing under the write fails red rather than looping" 1 "kept changing"
# Whoever won the race may have written a file this would have refused to touch on the first read.
# Retrying past that check would write over exactly the state ADR 0005 says stops the write — and
# with the version landing on the first line, which is what release post-processing reads.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/out-of-order.txt"
run "a conflict whose winner left the file out of order refuses, it does not retry over it" 1 \
  "which is not descending"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/malformed-line.txt"
run "a conflict whose winner left an unusable line refuses too" 1 "not an X.Y.Z"
# And it still reports per ledger. Refusing by exiting on this path would drop the summary that
# says the tag and the release ARE in place — which is precisely how the operator of 2.0.15 came
# to believe the recovery was finished.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/out-of-order.txt"
run "a refusal after the tag and release are written still reports every ledger" 1 \
  "release log    FAILED" "" ""
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-then-ok
LOG_FILE_2="$fixtures/out-of-order.txt"
run "and says the tag and release are already in place" 1 "tag v2.0.15    already in place"
# A 422 is not only a conflict: it also covers a malformed request. Retrying that would burn the
# one retry on a bug and report the wrong cause.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=conflict-twice
run "a refusal with no change to the file is reported as not a conflict" 1 "not a conflict"
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=refused
run "a write the credential cannot make fails red, naming the repository" 1 "refused the write"
# The PUT's own response is the confirmation: a GET right after a write can be served from cache,
# which is the race wait-for-tag-ref.sh exists for on the ref side.
base; APPLY_FLAG="--apply"; TAG_STATE=at-built REL_STATE=published; PUT=no-commit
run "a write accepted without a commit in the response is not treated as done" 1 "returned no commit"

echo
echo "recover-release scenarios: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
