#!/usr/bin/env bash
#
# Answer one question: is <version> already recorded in the release log for <module>?
# Prints "true" or "false" on stdout. Exits non-zero only when the arguments are unusable.
#
# Why this exists as its own script rather than inline in common-register-release.yml: the
# inline version did the exact opposite of what it was written to do, and nothing could catch
# that because a reusable workflow's step cannot be invoked from a test.
#
# It carried `set -uo pipefail` and a comment asserting that the step "omits set -e" — but a
# `run:` block executes under `bash -e {0}`, and `set -uo` does not remove the `-e` that came
# from the shell invocation. So the very first lookup,
#
#     encoded="$(gh api repos/<log>/contents/<module>.txt --jq .content 2>/dev/null | tr -d '\n')"
#
# aborted the whole step whenever `gh` exited non-zero — which is the ordinary case for a
# module with no log file yet (HTTP 404). The step died with no output at all, and `Launch
# action using REST` is gated on success(), so the release was never registered: the precise
# opposite of the intended fail-open. Observed on octopus-cve-validation-service 2.0.2,
# run 33184773170, the first release of a component not yet present in the log.
#
# Deliberately fail-open: anything short of a POSITIVE match prints "false" and the caller
# registers. A missing entry stalls the release pipeline, while a duplicate one only repeats
# bookkeeping — and duplicates cannot be prevented from here in any case (see #174).
#
# Usage: release-log-has-version.sh <release-log-repo> <module> <version>
#
# Every failure path is answered inside an `if` condition or with an explicit fallback, so the
# result does not depend on which shell flags the caller happens to be running under.
set -uo pipefail

repo=${1:?usage: release-log-has-version.sh <release-log-repo> <module> <version>}
module=${2:?usage: release-log-has-version.sh <release-log-repo> <module> <version>}
version=${3-}

# A version that is empty, blank, or spans more than one line means the caller failed to
# resolve it, and each shape breaks the check in its own way:
#
#   empty / blank  matches a blank line in the log and reads as "already registered", so
#                  nothing is registered at all;
#   multi-line     is worse — `grep -F` splits its pattern on newlines into SEVERAL patterns,
#                  so a match on any one of them reports the whole version as registered.
#                  Asking about $'2.0.99\n2.0.15' against a log holding 2.0.15 answers "true",
#                  and 2.0.99 is then never recorded.
#
# This is the one condition that must stop the release rather than fail open.
if [[ ! "$version" =~ ^[^[:space:]]+$ ]]; then
    echo "::error title=No usable version to register::The caller passed \"${version}\" as the release version, which is empty, blank, or spans more than one line." >&2
    exit 1
fi

# The lookup lives in an `if` condition precisely because a 404 is expected: a module released
# for the first time has no file in the log. Assigning from the command substitution instead
# would make that ordinary case abort the script under `set -e`.
encoded=""
if raw="$(gh api "repos/${repo}/contents/${module}.txt" --jq '.content' 2>/dev/null)"; then
    # The contents API returns base64 wrapped across lines. `|| fallback` rather than a bare
    # assignment: a command substitution that fails would otherwise abort the script under a
    # caller's `set -e`, on a path whose whole purpose is to fail open. Parameter expansion
    # would also be failure-proof, but `${raw//...}` is quadratic — on bash 3.2 a 59 KB
    # payload takes ~3 minutes — and a hang on a fail-open path is worse than a failure.
    encoded="$(printf '%s' "$raw" | LC_ALL=C tr -d '\n')" || encoded="$raw"
fi

# It also returns an empty payload for files it will not inline (over ~1 MB), which decodes to
# garbage rather than failing; treat that as unreadable.
log=""
if [ -n "$encoded" ] && [ "$encoded" != "null" ]; then
    # Two things must hold before the text is searched.
    #
    # First the payload has to LOOK like base64. Decoders disagree about malformed input —
    # GNU coreutils errors out, BSD/macOS decodes what it can and reports success — so
    # without a syntax check the outcome would depend on which coreutils the runner ships,
    # and on BSD the partial bytes would be searched. Checking first makes it the same
    # everywhere.
    #
    # Second the decode itself has to succeed. Searching partially decoded bytes could
    # produce a match that skips registration — the opposite of the intended fail-open.
    # The length test is not redundant with the alphabet test: a payload truncated mid-way is
    # still all-alphabet, and BSD base64 decodes as many whole quads as it can and reports
    # SUCCESS, so a truncated log would be searched — and a version whose line survived the
    # truncation would answer "already registered" for a log that never decoded.
    if [ $(( ${#encoded} % 4 )) -eq 0 ] \
        && [[ "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
        && decoded="$(base64 -d <<<"$encoded" 2>/dev/null)"; then
        # Strip CR so the whole-line match still works if the log ever gains CRLF endings;
        # without it the guard would silently never match. `|| fallback` because `tr` fails
        # with "Illegal byte sequence" on bytes that are not text in the current locale, and
        # a bare assignment would take the step down with it.
        log="$(LC_ALL=C tr -d '\r' <<<"$decoded")" || log="$decoded"
    else
        echo "Release log for ${module} could not be decoded; registering." >&2
    fi
fi

if [ -z "$log" ]; then
    echo "Release log for ${module} could not be read (new module, or a read failure); registering." >&2
    echo false
    exit 0
fi

# Whole-line, fixed-string: a substring match would read 2.0.15 as present in a log that only
# contains 12.0.15, and skip a registration that never happened.
# `--` so a version that begins with a dash is compared as text rather than read as an option.
if grep -qxF -- "$version" <<<"$log"; then
    echo "::notice title=Already registered::${module} ${version} is already in the release log; skipping." >&2
    echo true
else
    echo false
fi
