#!/usr/bin/env bash
# Scenarios for resolve-released-version.sh.
#
# git and gh are replaced by the stubs next to this file (put on PATH), so tag layouts
# that would otherwise need a crafted repository — several version tags on one commit, a
# higher unrelated tag elsewhere, a release cut from a commit the run never reported —
# are exercised directly. Each stub answers exactly one invocation and exits 99 on
# anything else, so a future change that reaches for the full tag list, or for another
# API call, fails this suite instead of passing quietly.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../resolve-released-version.sh"

failures=0
checks=0

# On success, stdout is compared EXACTLY: the workflow assigns it to a step output,
# which is a single line, so anything the helper adds to stdout would be silently
# truncated into the registered version. On failure, stdout must be empty and the
# reason is matched against stderr.
run() { # name expected_status expected_stdout_or_stderr_regex [stderr_regex] env...
  local name="$1" want_status="$2" want_main="$3"
  shift 3
  local want_err=""
  if [ "${1:-}" != "" ] && [[ "$1" != *=* ]]; then
    want_err="$1"
    shift
  fi
  checks=$((checks + 1))
  local outfile errfile out err status
  outfile="$(mktemp)"
  errfile="$(mktemp)"
  # Blank every variable the script or the stubs read before applying the scenario's
  # own values (later assignments win). Without this the ambient environment leaks in:
  # GitHub Actions sets GITHUB_REPOSITORY, which silently defeated the scenario that
  # checks behaviour when the repository is unknown — it passed locally and failed in CI.
  PATH="$here:$PATH" env \
    EXPLICIT_VERSION= RELEASE_RUN_ID= RELEASE_RUN_ATTEMPT= RELEASE_RUN_SHA= \
    GITHUB_REPOSITORY= GH_TOKEN= \
    TAGS_AT_SHA= TAGS_FOR_SHA= LATEST_RELEASE_TAG= LATEST_RELEASE_FAILS= STAMP_LOOKUP_FAILS= \
    STAMP_ON_LATER_PAGE= \
    STAMPED_RELEASE_TAG= STAMPED_FOR_RUN= \
    "$@" bash "$script" >"$outfile" 2>"$errfile"
  status=$?
  out="$(cat "$outfile")"
  err="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"

  local problem=""
  if [ "$status" -ne "$want_status" ]; then
    problem="expected exit $want_status, got $status"
  elif [ "$want_status" -eq 0 ]; then
    if [ "$out" != "$want_main" ]; then
      problem="stdout was not exactly '$want_main'"
    fi
  else
    if [ -n "$out" ]; then
      problem="a failing run must print nothing to stdout"
    elif ! grep -qE "$want_main" <<<"$err"; then
      problem="stderr did not match /$want_main/"
    fi
  fi
  if [ -z "$problem" ] && [ -n "$want_err" ] && ! grep -qE "$want_err" <<<"$err"; then
    problem="stderr did not match /$want_err/"
  fi

  if [ -n "$problem" ]; then
    echo "FAIL [$name]: $problem"
    echo "       stdout: $out"
    echo "       stderr: $err"
    failures=$((failures + 1))
    return
  fi
  echo "ok   [$name]"
}

common=(GITHUB_REPOSITORY=octopusden/octopus-test GH_TOKEN=stub)

# Source 1 — what the caller says, with or without the tag prefix.
run 'explicit version' 0 '2.5.2' EXPLICIT_VERSION=2.5.2 TAGS_AT_SHA='v1.0.0' "${common[@]}"
run 'explicit version with v prefix' 0 '2.5.2' EXPLICIT_VERSION=v2.5.2 TAGS_AT_SHA='' "${common[@]}"
run 'explicit garbage is rejected' 1 'not a version number' EXPLICIT_VERSION=latest "${common[@]}"

# Source 2 — the release stamped with this run's id: exact, and it wins over both
# fallbacks even when they would answer differently.
run 'release stamped with this run' 0 '2.2.38' 'stamped with run 555, attempt 1' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=1 STAMPED_FOR_RUN=555/1 STAMPED_RELEASE_TAG=v2.2.38 \
  RELEASE_RUN_SHA=cdfdd24d TAGS_FOR_SHA=cdfdd24d TAGS_AT_SHA='v2.2.37' \
  LATEST_RELEASE_TAG=v9.9.9 "${common[@]}"
run 'a stamp for another run is ignored' 0 '2.2.37' 'predates the stamping step' \
  RELEASE_RUN_ID=777 RELEASE_RUN_ATTEMPT=1 STAMPED_FOR_RUN=555/1 STAMPED_RELEASE_TAG=v2.2.38 \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"
# A rerun keeps the run id and bumps the attempt, and the public flow recomputes the
# version, so the first attempt's release must not answer for the second.
run 'a stamp from an earlier attempt is ignored' 0 '2.2.37' 'predates the stamping step' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=2 STAMPED_FOR_RUN=555/1 STAMPED_RELEASE_TAG=v2.2.38 \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"
run 'the matching attempt answers' 0 '2.2.39' 'attempt 2' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=2 STAMPED_FOR_RUN=555/2 STAMPED_RELEASE_TAG=v2.2.39 \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"
# Without an attempt the stamp cannot be addressed at all, so it is skipped rather than
# matched loosely.
run 'no attempt means no stamp lookup' 0 '2.2.37' 'without an attempt number' \
  RELEASE_RUN_ID=555 STAMPED_FOR_RUN=555/1 STAMPED_RELEASE_TAG=v2.2.38 \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"

# Source 3 — exactly one version tag on the commit the run reported.
run 'single tag on the reported commit' 0 '2.2.37' 'only version tag' \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' "${common[@]}"
run 'non-semver tags are not candidates' 0 '2.2.37' \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='latest v9.9.9-pr99 v2.2.37 release-2' "${common[@]}"

# The bug this replaced: a higher tag exists elsewhere in the repository. It must never
# win — not through the tag list (the stub rejects any call that asks for it) and not
# through the latest release, which is ordered by creation time, so an older canary
# loses to a newer real release.
run 'higher unrelated tag never wins' 0 '2.2.37' \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' LATEST_RELEASE_TAG=v9.9.9 "${common[@]}"

# Source 4 — the reported commit cannot answer either, so fall back to the newest
# release. This
# is the hybrid-flow case: the run reports the default branch tip while the release was
# cut from, and tagged on, a different commit.
run 'no tag on the reported commit falls back' 0 '2.2.37' \
  RELEASE_RUN_SHA=deadbeef TAGS_FOR_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"
run 'several tags on one commit fall back' 0 '2.2.36' 'several version tags' \
  RELEASE_RUN_SHA=cdfdd24d TAGS_FOR_SHA=cdfdd24d TAGS_AT_SHA='v2.2.35 v2.2.36' LATEST_RELEASE_TAG=v2.2.36 "${common[@]}"
run 'fallback explains itself' 0 '2.2.37' 'most recently created release' \
  RELEASE_RUN_SHA=deadbeef TAGS_FOR_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"

# A stamp that exists but sits past the first page must still be found: three consumer
# repositories already hold more than 50 releases. Reading one page and calling the miss
# "predates stamping" hands the answer to the tag/latest fallback, which can name a version
# another run released. The stub rejects an unpaginated list call outright, and puts the
# match behind two empty page results here.
run 'stamp on a later page is still found' 0 '2.2.38' 'stamped with run 555' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=1 STAMPED_FOR_RUN=555/1 STAMPED_RELEASE_TAG=v2.2.38 \
  STAMP_ON_LATER_PAGE=1 \
  RELEASE_RUN_SHA=178e83a0 TAGS_FOR_SHA=178e83a0 TAGS_AT_SHA='v2.2.37' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"

# A failed stamp lookup is not an unstamped release. Falling through would let the tag an
# EARLIER release left on the commit this run reports answer for this one — silently, and
# with every job green, because the release log's dedup step then skips the version that
# really shipped. Both scenarios below pass trivially if that distinction is dropped.
run 'failed stamp lookup does not read as unstamped' 1 'Refusing to fall back to tag topology' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=1 STAMP_LOOKUP_FAILS=1 \
  RELEASE_RUN_SHA=tipsha TAGS_FOR_SHA=tipsha TAGS_AT_SHA='v2.2.36' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"
run 'failed stamp lookup does not fall through to the latest release either' 1 'Re-run when the API is reachable' \
  RELEASE_RUN_ID=555 RELEASE_RUN_ATTEMPT=1 STAMP_LOOKUP_FAILS=1 \
  RELEASE_RUN_SHA=deadbeef TAGS_FOR_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=v2.2.37 "${common[@]}"

# Nothing can answer: fail with something actionable rather than registering a guess.
run 'no tag and no readable release' 1 'Pass release-version explicitly' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_FAILS=1 "${common[@]}"
run 'no tag and no release at all' 1 'Pass release-version explicitly' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=null "${common[@]}"
run 'latest release is not a version tag' 1 'not a plain version number' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' LATEST_RELEASE_TAG=nightly-2026-07-27 "${common[@]}"
run 'no repository to look up' 1 'repository is unknown' \
  RELEASE_RUN_SHA=deadbeef TAGS_AT_SHA='' GH_TOKEN=stub

echo
if [ "$checks" -eq 0 ]; then
  echo "No scenarios ran — the suite would have passed vacuously." >&2
  exit 1
fi
if [ "$failures" -eq 0 ]; then
  echo "All $checks scenarios passed."
else
  echo "$failures of $checks scenarios failed."
fi
exit $((failures > 0))
