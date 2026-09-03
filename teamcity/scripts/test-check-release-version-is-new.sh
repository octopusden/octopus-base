#!/usr/bin/env bash
# Behaviour of check-release-version-is-new.sh, plus proof that the copy embedded in
# teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml has not drifted from it.
# TeamCity cannot source a script from a repository, so the meta-runner must carry a copy;
# this is what stops the two diverging.
cd "$(dirname "$0")"
script=./check-release-version-is-new.sh
xml=../../teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml
pass=0; fail=0

check() { # <desc> <expect-regex> <build> <last>
  out="$(BUILD_NUMBER="$3" LAST_RELEASE_VERSION="$4" bash "$script" 2>&1)"
  if grep -qE "$2" <<<"$out"; then echo "PASS [$1]"; pass=$((pass+1))
  else echo "FAIL [$1]"; sed 's/^/       /' <<<"$out"; fail=$((fail+1)); fi
}

check "equal: green status"            "buildStatus text='2.0.16 already processed" 2.0.16 2.0.16
check "equal: skips the Jira steps"    "setParameter name='ALREADY_PROCESSED' value='true'"  2.0.16 2.0.16
check "newer: proceeds"                "setParameter name='ALREADY_PROCESSED' value='false'" 2.0.17 2.0.16
check "older: log went backwards"      "identity='releaselog_regressed'"      2.0.15 2.0.16
check "much older: log went backwards" "identity='releaselog_regressed'"      2.0.2  2.0.16
check "numeric order, not lexical"     "value='false'"                        2.0.10 2.0.9
check "numeric order both ways"        "identity='releaselog_regressed'"      2.0.9  2.0.10
check "empty version"                  "identity='releaselog_bad_version'"    ""     2.0.16
check "non-version"                    "identity='releaselog_bad_version'"    "x.y"  2.0.16
check "empty last-release"             "identity='releaselog_bad_lastrelease'" 2.0.16 ""
check "quote is service-msg escaped"   "\|'"                                  "2.0.'16" 2.0.16
check "problem also logs an ERROR line" "##teamcity\[message text=.*status='ERROR'\]" 2.0.15 2.0.16

# Non-zero exit on every real problem, zero on both good outcomes.
for c in "2.0.16 2.0.16 0" "2.0.17 2.0.16 0" "2.0.15 2.0.16 1" "x 2.0.16 1"; do
  set -- $c
  BUILD_NUMBER="$1" LAST_RELEASE_VERSION="$2" bash "$script" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS [exit $3 for $1 vs $2]"; pass=$((pass+1))
  else echo "FAIL [exit: $1 vs $2 gave $rc, want $3]"; fail=$((fail+1)); fi
done

# Drift check: the meta-runner must carry this script byte for byte. The values are bound as
# environment variables, so nothing has to be rewritten for the embedded copy - which is the
# point: a %PARAM% substituted into the script body would be executed, not read.
embedded="$(awk '/<!\[CDATA\[/{sub(/.*<!\[CDATA\[/,"");f=1} f{if(/\]\]>/){sub(/\]\]>.*/,"");if(length)print;exit} print}' "$xml")"
if [ "$embedded" = "$(cat "$script")" ]; then echo "PASS [meta-runner copy is byte-identical]"; pass=$((pass+1))
else echo "FAIL [meta-runner copy has drifted]"; diff <(cat "$script") <(printf '%s\n' "$embedded") | sed 's/^/       /'; fail=$((fail+1)); fi

# The embedded copy must contain no %PARAM% inside the script body. TeamCity substitutes those
# into the source before the agent runs it, so such a value executes before any validation
# below can look at it - and BUILD_NUMBER is the first line of a release-log file.
# Comments are stripped first: this file's own comments mention the pattern by name.
code="$(sed 's/#.*//' <<<"$embedded")"
if grep -q '%[A-Za-z_.][A-Za-z0-9_.]*%' <<<"$code"; then
  echo "FAIL [embedded script interpolates a TeamCity parameter - injectable]"
  grep -n '%[A-Za-z_.][A-Za-z0-9_.]*%' <<<"$code" | sed 's/^/       /'; fail=$((fail+1))
else echo "PASS [embedded script interpolates no TeamCity parameter]"; pass=$((pass+1)); fi

# And prove it: feed the embedded copy a value that would execute if it were substituted.
marker="$(mktemp -u)"
evil="\"; : > ${marker}; x=\""
BUILD_NUMBER="$evil" LAST_RELEASE_VERSION=2.0.16 bash <(printf '%s\n' "$embedded") >/dev/null 2>&1
if [ -e "$marker" ]; then echo "FAIL [embedded copy executed an injected command]"; rm -f "$marker"; fail=$((fail+1))
else echo "PASS [embedded copy treats a hostile value as data]"; pass=$((pass+1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
