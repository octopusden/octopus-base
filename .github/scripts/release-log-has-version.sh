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

# An empty version would match any blank line in the log and read as "already registered", so
# a caller that failed to resolve its version would silently register nothing at all. This is
# the one condition that must stop the release rather than fail open.
if [ -z "$version" ]; then
    echo "::error title=No version to register::The caller passed an empty release version." >&2
    exit 1
fi

# The lookup lives in an `if` condition precisely because a 404 is expected: a module released
# for the first time has no file in the log. Assigning from the command substitution instead
# would make that ordinary case abort the script under `set -e`.
encoded=""
if raw="$(gh api "repos/${repo}/contents/${module}.txt" --jq '.content' 2>/dev/null)"; then
    # The contents API returns base64 wrapped across lines. Stripped with parameter
    # expansion rather than a pipeline: every command substitution here is one more way
    # for the step to die on a path that is supposed to fail open.
    encoded="${raw//$'\n'/}"
fi

# It also returns an empty payload for files it will not inline (over ~1 MB), which decodes to
# garbage rather than failing; treat that as unreadable.
log=""
if [ -n "$encoded" ] && [ "$encoded" != "null" ]; then
    # Keep the decoded text only if decoding actually succeeded: base64 can emit valid bytes
    # before reporting malformed input, and searching that partial text could produce a match
    # that skips registration — again the opposite of the intended fail-open.
    if decoded="$(base64 -d <<<"$encoded" 2>/dev/null)"; then
        # Strip CR so the whole-line match still works if the log ever gains CRLF endings;
        # without it the guard would silently never match.
        #
        # Not `tr -d '\r'`: base64 implementations disagree about malformed input — GNU
        # coreutils errors out, BSD/macOS decodes what it can and succeeds — so `decoded`
        # can hold arbitrary bytes, and `tr` then fails with "Illegal byte sequence" and
        # takes the step down with it. Parameter expansion cannot fail.
        log="${decoded//$'\r'/}"
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
if grep -qxF "$version" <<<"$log"; then
    echo "::notice title=Already registered::${module} ${version} is already in the release log; skipping." >&2
    echo true
else
    echo false
fi
