#!/usr/bin/env bash
# Behaviour of check-release-version-is-new.sh, plus proof that the copy embedded in
# teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml has not drifted from it.
#
# Every case compares the COMPLETE output and exit code, not a grep. A suite of positive
# greps passes on an implementation that emits every service message on every path - which
# is how an injection and a fail-open comparison both got through review of this file once.
cd "$(dirname "$0")"
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
for pair in "|:||" "':|'" "[:|[" "]:|]"; do
  ch=${pair%%:*}; want=${pair#*:}
  out="$(run "2.0.16${ch}" 2.0.16)"
  if grep -qF "buildNumber: 2.0.16${want}" <<<"$out"; then
    echo "PASS [escapes '${ch}']"; pass=$((pass + 1))
  else echo "FAIL [does not escape '${ch}']"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
done
out="$(run "$(printf '2.0.16\rX')" 2.0.16)"
if grep -qF 'buildNumber: 2.0.16|rX' <<<"$out"; then echo "PASS [escapes CR]"; pass=$((pass + 1))
else echo "FAIL [does not escape CR]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# The verdict must not depend on any external command: a `sort` that could not do -V used to
# make this script report an OLDER version as newer, with exit 0.
stub="$(mktemp -d)"
for c in sort awk sed grep cut tr head tail; do printf '#!/bin/sh\nexit 2\n' > "$stub/$c"; chmod +x "$stub/$c"; done
out="$(PATH="$stub:/usr/bin:/bin" BUILD_NUMBER=2.0.9 LAST_RELEASE_VERSION=2.0.16 bash "$script" 2>&1)"
if grep -q "releaselog_regressed" <<<"$out"; then echo "PASS [verdict needs no external command]"; pass=$((pass + 1))
else echo "FAIL [verdict changed when external commands were broken]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
rm -rf "$stub"

# TeamCity cannot source a script from a repository, so the meta-runner carries a copy. The
# values are bound as environment variables, so nothing has to be rewritten for that copy -
# which is the point: a %PARAM% substituted into the script body would be executed, not read.
embedded="$(awk '/<!\[CDATA\[/{sub(/.*<!\[CDATA\[/,"");f=1} f{if(/\]\]>/){sub(/\]\]>.*/,"");if(length)print;exit} print}' "$xml")"
if [ "$embedded" = "$(cat "$script")" ]; then echo "PASS [meta-runner copy is byte-identical]"; pass=$((pass + 1))
else echo "FAIL [meta-runner copy has drifted]"; diff <(cat "$script") <(printf '%s\n' "$embedded") | sed 's/^/       /'; fail=$((fail + 1)); fi

# Comments are stripped first: this file's own comments mention the pattern by name.
if grep -q '%[A-Za-z_.][A-Za-z0-9_.]*%' <<<"$(sed 's/#.*//' <<<"$embedded")"; then
  echo "FAIL [embedded script interpolates a TeamCity parameter - injectable]"; fail=$((fail + 1))
else echo "PASS [embedded script interpolates no TeamCity parameter]"; pass=$((pass + 1)); fi

marker="$(mktemp -u)"
BUILD_NUMBER="\"; : > ${marker}; x=\"" LAST_RELEASE_VERSION=2.0.16 bash <(printf '%s\n' "$embedded") >/dev/null 2>&1
if [ -e "$marker" ]; then echo "FAIL [embedded copy executed an injected command]"; rm -f "$marker"; fail=$((fail + 1))
else echo "PASS [embedded copy treats a hostile value as data]"; pass=$((pass + 1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
