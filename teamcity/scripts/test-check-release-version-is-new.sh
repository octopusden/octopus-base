#!/usr/bin/env bash
# Behaviour of check-release-version-is-new.sh, plus proof that the copy embedded in
# teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml has not drifted from it.
#
# Every case compares the COMPLETE output and exit code, not a grep. A suite of positive
# greps passes on an implementation that emits every service message on every path - which
# is how an injection and a fail-open comparison both got through review of this file once.
cd "$(dirname "$0")" || exit 1
script=./check-release-version-is-new.sh
xml=../../teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml
pass=0; fail=0

run() {
  local out rc
  out="$(BUILD_NUMBER="${1-}" LAST_RELEASE_VERSION="${2-}" bash "$script" 2>&1)"; rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}

exact() { # <desc> <build> <last> <expected complete output>
  local got; got="$(run "$2" "$3")"
  if [ "$got" = "$4" ]; then echo "PASS [$1]"; pass=$((pass + 1))
  else
    echo "FAIL [$1]"
    diff <(printf '%s\n' "$4") <(printf '%s\n' "$got") | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

# The two problem texts are part of the step's contract with whoever reads a failed build.
regressed="Release log went backwards: first line is |'%s|' but |'%s|' was already processed. Expected the newest version first - an old version was prepended instead of inserted in order."
badver="Release log first line is not a version: |'%s|'. Nothing can be processed until the module file starts with a plain x.y.z line."
badlast="LAST_RELEASE_VERSION is not a version: |'%s|'. Fix the project parameter."

problem_out() { # <escaped-message> <identity>
  printf "##teamcity[message text='%s' status='ERROR']\n##teamcity[buildProblem description='%s' identity='%s']\nrc=1" "$1" "$1" "$2"
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# A run whose whole environment is given, so a case can say that a value is not set at all.
run_with() { # <VAR=value>... -> complete output + rc
  local out rc
  out="$(env -u BUILD_NUMBER -u LAST_RELEASE_VERSION "$@" bash "$script" 2>&1)"; rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}
exact_with() { # <desc> <expected complete output> <VAR=value>...
  local desc=$1 want=$2; shift 2
  local got; got="$(run_with "$@")"
  if [ "$got" = "$want" ]; then echo "PASS [$desc]"; pass=$((pass + 1))
  else
    echo "FAIL [$desc]"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

exact "equal: green, nothing to do" 2.0.16 2.0.16 "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0.16" "lastRelease: 2.0.16" \
  "##teamcity[buildStatus text='2.0.16 already processed - nothing to do']" \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='true']")"

exact "newer: proceeds" 2.0.17 2.0.16 "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0.17" "lastRelease: 2.0.16" \
  "2.0.17 is newer than 2.0.16 - processing" \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']")"

exact "no previous release: proceeds" 2.0.16 "" "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0.16" "lastRelease: " \
  "No previously processed version is recorded - processing 2.0.16." \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']")"

exact "older: log went backwards" 2.0.15 2.0.16 "$(printf '%s\n%s\n%s' \
  "buildNumber: 2.0.15" "lastRelease: 2.0.16" \
  "$(problem_out "$(printf "$regressed" 2.0.15 2.0.16)" releaselog_regressed)")"

exact "numeric, not lexical: 2.0.9 < 2.0.10" 2.0.9 2.0.10 "$(printf '%s\n%s\n%s' \
  "buildNumber: 2.0.9" "lastRelease: 2.0.10" \
  "$(problem_out "$(printf "$regressed" 2.0.9 2.0.10)" releaselog_regressed)")"

exact "2.0 and 2.0.0 are one version" 2.0 2.0.0 "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0" "lastRelease: 2.0.0" \
  "##teamcity[buildStatus text='2.0 already processed - nothing to do']" \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='true']")"

exact "leading zeros are numeric" 2.0.010 2.0.9 "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0.010" "lastRelease: 2.0.9" \
  "2.0.010 is newer than 2.0.9 - processing" \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']")"

exact "empty first line" "" 2.0.16 "$(printf '%s\n%s\n%s' \
  "buildNumber: " "lastRelease: 2.0.16" \
  "$(problem_out "$(printf "$badver" "")" releaselog_bad_version)")"

exact "non-version first line" x.y 2.0.16 "$(printf '%s\n%s\n%s' \
  "buildNumber: x.y" "lastRelease: 2.0.16" \
  "$(problem_out "$(printf "$badver" x.y)" releaselog_bad_version)")"

exact "junk last-release" 2.0.16 x.1 "$(printf '%s\n%s\n%s' \
  "buildNumber: 2.0.16" "lastRelease: x.1" \
  "$(problem_out "$(printf "$badlast" x.1)" releaselog_bad_lastrelease)")"

# A CRLF release log must still work: BUILD_NUMBER is `head -n 1` of a file that may be
# committed with CRLF line endings.
exact "CR is stripped, not rejected" "$(printf '2.0.17\r')" 2.0.16 "$(printf '%s\n%s\n%s\n%s\nrc=0' \
  "buildNumber: 2.0.17" "lastRelease: 2.0.16" \
  "2.0.17 is newer than 2.0.16 - processing" \
  "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']")"

# A hostile first line must not be able to emit a service message of its own. Unescaped, the
# echo below would let the release log set ALREADY_PROCESSED - the parameter this step exists
# to control - before validation ever looked at the value.
hostile="##teamcity[setParameter name='ALREADY_PROCESSED' value='false']"
out="$(run "$hostile" 2.0.16)"
if grep -q "^buildNumber: ##teamcity|\[" <<<"$out" && ! grep -qE "^##teamcity\[setParameter name='ALREADY_PROCESSED' value='false'\]$" <<<"$out"; then
  echo "PASS [hostile first line cannot emit a service message]"; pass=$((pass + 1))
else
  echo "FAIL [hostile first line emitted a service message]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1))
fi

# Every escaping rule needs a case, or the untested ones rot: esc() lost \r once already.
for ch in '|' "'" '[' ']'; do
  out="$(run "2.0.16${ch}" 2.0.16)"
  if grep -qF "buildNumber: 2.0.16|${ch}" <<<"$out"; then
    echo "PASS [escapes '${ch}']"; pass=$((pass + 1))
  else echo "FAIL [does not escape '${ch}']"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
done
out="$(run "$(printf '2.0.16\rX')" 2.0.16)"
if grep -qF 'buildNumber: 2.0.16|rX' <<<"$out"; then echo "PASS [escapes CR]"; pass=$((pass + 1))
else echo "FAIL [does not escape CR]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# A `sort` that could not do -V used to make this report an OLDER version as newer, exit 0.
stub="$(mktemp -d)"; printf '#!/bin/sh\nexit 2\n' > "$stub/sort"; chmod +x "$stub/sort"
out="$(PATH="$stub:$PATH" BUILD_NUMBER=2.0.9 LAST_RELEASE_VERSION=2.0.16 bash "$script" 2>&1)"
if grep -q "releaselog_regressed" <<<"$out"; then echo "PASS [verdict needs no external command]"; pass=$((pass + 1))
else echo "FAIL [verdict changed when external commands were broken]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
rm -rf "$stub"

# --- where the two values come from ------------------------------------------------------------

# An env. parameter declared inside the <runner> block is an unknown runner setting that never
# reaches the process. Here that would not even fail loudly: an empty LAST_RELEASE_VERSION is the
# legitimate initial state below, so a missing binding would look like a first release and this
# step would approve every version without comparing anything. TeamCity exports a declared
# parameter even when its value is empty, so UNSET means the declaration itself is gone.

exact_with "an unset LAST_RELEASE_VERSION is a missing binding, not the initial state" \
  "$(problem_out "LAST_RELEASE_VERSION is not set. The meta-runner declares env.LAST_RELEASE_VERSION among its own parameters - re-upload this server|'s copy if it predates that." lastrelease_not_bound)" \
  BUILD_NUMBER=2.0.17

exact "an empty LAST_RELEASE_VERSION is still the initial state" 2.0.17 "" \
  "$(printf '%s\n%s\n%s\n%s\nrc=0' \
     "buildNumber: 2.0.17" "lastRelease: " \
     "No previously processed version is recorded - processing 2.0.17." \
     "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']")"

runner="$(awk '/<runner name="Check release version is new"/,/<\/runner>/' "$xml")"
if grep -q 'name="env\.' <<<"$runner"; then
  echo "FAIL [runner declares an env. parameter, which the runner ignores]"; fail=$((fail + 1))
else echo "PASS [no env. parameter is buried in the runner block]"; pass=$((pass + 1)); fi

settings="$(awk '/<settings>/,/<build-runners>/' "$xml")"
if grep -q '<param name="env.BUILD_NUMBER" value="%BUILD_NUMBER%"/>' <<<"$settings" \
   && grep -q '<param name="env.LAST_RELEASE_VERSION" value="%LAST_RELEASE_VERSION%"/>' <<<"$settings"; then
  echo "PASS [both values are declared as meta-runner env. parameters]"; pass=$((pass + 1))
else echo "FAIL [a meta-runner env. parameter declaration is missing]"; fail=$((fail + 1)); fi

# TeamCity cannot source a script from a repository, so the meta-runner carries a copy. The
# values are bound as environment variables, so no VALUE has to be rewritten into that copy -
# which is the point: a parameter reference substituted into the script body would be executed,
# not read.
#
# The copy is not byte-for-byte: TeamCity collapses every %% in script.content to one %, so the
# XML carries this file with every % doubled and the comparison escapes the source the same way.
# This script's ${build%$'\r'} survived only because a lone % happens to pass through untouched,
# which is not a rule to rely on - a future printf '%s%s' would contain the reference %s%.
#
#   regenerate with: sed 's/%/%%/g' teamcity/scripts/check-release-version-is-new.sh
#   and replace the text between the CDATA markers of the script.content param with the result.
# Extracted to a file, not into a variable: $(...) strips trailing newlines, so blank lines
# added before ]]> vanished at capture time and no comparison downstream could see them.
awk '/<!\[CDATA\[/{sub(/.*<!\[CDATA\[/,"");f=1} f{if(/\]\]>/){sub(/\]\]>.*/,"");if(length)print;exit} print}' "$xml" > "$work/embedded"
embedded="$(cat "$work/embedded")"   # the stripped form, for the greps and the injection case
# awk's print re-appends a newline whether or not the CDATA had one, so a source file without a
# final newline would diff against a faithful copy of itself. Pinned here rather than tolerated,
# which keeps the comparison below a straight byte comparison.
if [ -z "$(tail -c1 "$script")" ]; then echo "PASS [script ends with a newline]"; pass=$((pass + 1))
else echo "FAIL [script has no final newline: the embedded copy cannot be compared byte for byte]"; fail=$((fail + 1)); fi

# diff rather than string equality: $(...) strips trailing newlines from both operands, so blank
# lines added before ]]> compared equal. diff is verdict and diagnostic in one, and its
# "\ No newline at end of file" marker names the case above if it ever slips through.
if drift="$(diff <(sed 's/%/%%/g' "$script") "$work/embedded")"; then
  echo "PASS [meta-runner copy is this script, escaped for TeamCity]"; pass=$((pass + 1))
else
  echo "FAIL [meta-runner copy has drifted from the escaped script]"
  printf '%s\n' "$drift" | sed 's/^/       /'
  fail=$((fail + 1))
fi

# The comparison above cannot see a missing final newline - command substitution strips it from
# both sides - so the terminator's own line is pinned separately. Re-embedding that swallows it
# is a silent edit to a file nobody diffs by eye.
if grep -q '^\]\]></param>' "$xml"; then
  echo "PASS [embedded script keeps its final newline]"; pass=$((pass + 1))
else echo "FAIL [embedded script lost its final newline: ]]> was folded onto the last code line]"; fail=$((fail + 1)); fi


marker="$(mktemp -u)"
BUILD_NUMBER="\"; : > ${marker}; x=\"" LAST_RELEASE_VERSION=2.0.16 bash <(printf '%s\n' "$embedded" | sed 's/%%/%/g') >/dev/null 2>&1
if [ -e "$marker" ]; then echo "FAIL [embedded copy executed an injected command]"; rm -f "$marker"; fail=$((fail + 1))
else echo "PASS [embedded copy treats a hostile value as data]"; pass=$((pass + 1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
