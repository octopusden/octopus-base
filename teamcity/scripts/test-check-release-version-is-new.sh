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
  out="$(bash "$script" "$3" "$4" 2>&1)"
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

# Non-zero exit on every real problem, zero on both good outcomes.
for c in "2.0.16 2.0.16 0" "2.0.17 2.0.16 0" "2.0.15 2.0.16 1" "x 2.0.16 1"; do
  set -- $c
  bash "$script" "$1" "$2" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$3" ]; then echo "PASS [exit $3 for $1 vs $2]"; pass=$((pass+1))
  else echo "FAIL [exit: $1 vs $2 gave $rc, want $3]"; fail=$((fail+1)); fi
done

# Drift check: the embedded copy must be the canonical script with only the argument
# binding replaced by the meta-runner parameters.
embedded="$(python3 - "$xml" <<'PY'
import re,sys,io
s=io.open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(re.search(r'<!\[CDATA\[(.*?)\]\]>', s, re.S).group(1))
PY
)"
expected="$(sed -e 's|^# Args: %build.number% %LAST_RELEASE_VERSION%$|# Args come from the meta-runner parameters below.|' \
                -e 's|^build="\${1-}"; last="\${2-}"$|build="%BUILD_NUMBER%"; last="%LAST_RELEASE_VERSION%"|' "$script")"
if [ "$embedded" = "$expected" ]; then echo "PASS [meta-runner copy matches the script]"; pass=$((pass+1))
else echo "FAIL [meta-runner copy has drifted]"; diff <(printf '%s' "$expected") <(printf '%s' "$embedded") | sed 's/^/       /'; fail=$((fail+1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
