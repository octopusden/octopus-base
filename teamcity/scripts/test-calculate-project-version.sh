#!/usr/bin/env bash
# Behaviour of calculate-project-version.sh, plus proof that the copy embedded in
# teamcity.meta-runners/OctopusCalculateBuildParameters.xml has not drifted from it.
#
# Every case compares the COMPLETE output and exit code, not a grep: a suite of positive greps
# passes on an implementation that emits every service message on every path.
cd "$(dirname "$0")"
script="$PWD/calculate-project-version.sh"
xml="$PWD/../../teamcity.meta-runners/OctopusCalculateBuildParameters.xml"
pass=0; fail=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# A fresh repository per case: one commit, the given tags, and optionally a .release-line.
default_branch=false   # reset per repo; a case that exercises the guard sets it to true
repo() { # <name> [tag...]
  local d="$work/$1"; shift
  git init -q "$d" && cd "$d" || exit 1
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local t; for t in "$@"; do git tag "$t"; done
  default_branch=false
}
line() { printf '%s' "$1" > .release-line; }   # exact bytes: the CRLF / no-newline case relies on it

run() { # [counter] -> complete output + rc, from the current directory
  local out rc
  out="$(BUILD_COUNTER="${1-1832}" IS_DEFAULT_BRANCH="$default_branch" bash "$script" 2>&1)"; rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}

exact() { # <desc> <expected complete output> [counter]
  local got; got="$(run "${3-1832}")"
  if [ "$got" = "$2" ]; then echo "PASS [$1]"; pass=$((pass + 1))
  else
    echo "FAIL [$1]"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$got") | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

ok() { # <version> <lines...> -> the complete output of a successful run
  local v=$1; shift
  printf '%s\n' "$@"
  printf "##teamcity[buildNumber '%s-1832']\n##teamcity[setParameter name='PROJECT_VERSION' value='%s']\nrc=0" "$v" "$v"
}
problem_out() { # <escaped-message> <identity>
  printf "##teamcity[message text='%s' status='ERROR']\n##teamcity[buildProblem description='%s' identity='%s']\nrc=1" "$1" "$1" "$2"
}

# --- the line is declared -----------------------------------------------------------------

repo a v2.0.9 v2.0.63 v1.9.99; line $'2.0\n'
exact "line continues: newest patch on the line + 1, in version order (2.0.63 > 2.0.9)" \
  "$(ok 2.0.64 "Release line: 2.0 (from .release-line)" "Newest tag on the line: v2.0.63")"

repo b v2.4.1 v2.6.0; line $'2.5\n'
exact "line opens: no tag on it yet -> .0; a stray higher tag changes nothing" \
  "$(ok 2.5.0 "Release line: 2.5 (from .release-line)" "No v2.5.* tag yet - opening the line")"

# The maintenance-branch case the file exists for: a branch declaring 2.4 keeps releasing 2.4.x
# after main has opened 2.5.
repo c v2.4.1 v2.5.0; line $'2.4\n'
exact "file is the authority: a newer line's tag does not pull the version up" \
  "$(ok 2.4.2 "Release line: 2.4 (from .release-line)" "Newest tag on the line: v2.4.1")"

repo d v2.0.6.1 v2.0.64-rc1 v2.0.5 v2.0.50x v2x0.7; line $'2.0\n'
exact "only vX.Y.N tags count: v2.0.6.1, v2.0.64-rc1, v2.0.50x, v2x0.7 are not on the line" \
  "$(ok 2.0.6 "Release line: 2.0 (from .release-line)" "Newest tag on the line: v2.0.5")"

repo e v2.0.3; line $'  2.0 \r'
exact "blanks, CR and a missing trailing newline are tolerated" \
  "$(ok 2.0.4 "Release line: 2.0 (from .release-line)" "Newest tag on the line: v2.0.3")"

repo e2 v2.0.0; line $'2.0\n'
exact "the line's first release counts: v2.0.0 present -> 2.0.1, not 2.0.0 again" \
  "$(ok 2.0.1 "Release line: 2.0 (from .release-line)" "Newest tag on the line: v2.0.0")"

repo f v2.0.3; line $'2.0.3\n'
exact "a full version in the file is refused: the file names a line, tags give the patch" \
  "$(problem_out ".release-line must hold major.minor on its first line, got |'2.0.3|'." releaseline_bad_format)"

repo f2 v2.5.3; line $'2.05\n'
exact "a zero-padded line is refused: it would be its own line here and 2.5 downstream" \
  "$(problem_out ".release-line must hold major.minor on its first line, got |'2.05|'." releaseline_bad_format)"

# --- the line may not go backwards on the default branch ------------------------------------

repo n1 v2.4.1 v2.8.0; line $'2.3\n'; default_branch=true
exact "default branch: a line behind the newest release is refused" \
  "$(printf '%s\n%s' "Release line: 2.3 (from .release-line)" \
     "$(problem_out ".release-line declares 2.3 but v2.8.0 is already released; on the default branch the line cannot go backwards." releaseline_behind)")"

# A maintenance branch is exactly the case the file exists for, so the guard stays off there.
repo n2 v2.4.1 v2.5.0; line $'2.4\n'; default_branch=false
exact "other branch: a line behind the newest release is allowed" \
  "$(ok 2.4.2 "Release line: 2.4 (from .release-line)" "Newest tag on the line: v2.4.1")"

repo n3 v2.8.0; line $'2.8\n'; default_branch=true
exact "default branch: the current line passes" \
  "$(ok 2.8.1 "Release line: 2.8 (from .release-line)" "Newest tag on the line: v2.8.0")"

repo n4 v2.8.0; line $'2.9\n'; default_branch=true
exact "default branch: opening the next line passes" \
  "$(ok 2.9.0 "Release line: 2.9 (from .release-line)" "No v2.9.* tag yet - opening the line")"

repo n5 v2.9.0 v2.10.0; line $'2.9\n'; default_branch=true
exact "the comparison is numeric: 2.9 is behind v2.10.0" \
  "$(printf '%s\n%s' "Release line: 2.9 (from .release-line)" \
     "$(problem_out ".release-line declares 2.9 but v2.10.0 is already released; on the default branch the line cannot go backwards." releaseline_behind)")"

repo n7; line $'2.0\n'; default_branch=true
exact "default branch: nothing released yet, nothing to be behind" \
  "$(ok 2.0.0 "Release line: 2.0 (from .release-line)" "No v2.0.* tag yet - opening the line")"

# Both directions of the major comparison. Without the major term the first is allowed - the
# very typo the guard exists for - and the second is refused, which would block every major bump.
repo n8 v3.0.0; line $'2.9\n'; default_branch=true
exact "default branch: a line behind by a major is refused" \
  "$(printf '%s\n%s' "Release line: 2.9 (from .release-line)" \
     "$(problem_out ".release-line declares 2.9 but v3.0.0 is already released; on the default branch the line cannot go backwards." releaseline_behind)")"

repo n9 v2.8.0; line $'3.0\n'; default_branch=true
exact "default branch: opening the next major passes" \
  "$(ok 3.0.0 "Release line: 3.0 (from .release-line)" "No v3.0.* tag yet - opening the line")"

# A non-release tag sorting above the newest release must be skipped, not end the search and not
# be compared against: either way one stray rc tag would decide the guard for the whole repository.
repo n10 v2.8.0 v2.9.0-rc1; line $'2.3\n'; default_branch=true
exact "a non-release tag above the newest release neither hides nor triggers the guard" \
  "$(printf '%s\n%s' "Release line: 2.3 (from .release-line)" \
     "$(problem_out ".release-line declares 2.3 but v2.8.0 is already released; on the default branch the line cannot go backwards." releaseline_behind)")"

# A zero-padded tag is refused whichever component carries it, before the line is even read. Each
# of these reached the calculation a different way while it was tolerated: v08.1.0 and v2.08.0 hid
# a higher release from the backwards check, v2.0.08 took a patch number that was already used,
# and adopting line 2.8 beside v2.08.4 reset that line's patch to 0.
padded_message() { printf "Version tag |'%s|' has a zero-padded component; a release tag must be vX.Y.Z with no leading zeros. Delete it or re-create it unpadded." "$1"; }
for padded in v08.1.0 v2.08.4 v2.0.08; do
  repo "pad-${padded}" "$padded"; line $'2.8\n'; default_branch=true
  exact "a zero-padded tag is refused: ${padded}" \
    "$(problem_out "$(padded_message "$padded")" version_padded_tag)"
done

# A tag that is not a version at all sorts above the padded one, so the scan must skip past it
# rather than stop there.
repo pad-behind-rc v2.08.0 v2.9.0-rc1; line $'2.8\n'; default_branch=true
exact "a zero-padded tag is found behind a tag that is not a version" \
  "$(problem_out "$(padded_message v2.08.0)" version_padded_tag)"

# The check precedes both branches, so a repository that has not adopted the file is refused too
# rather than releasing 2.08.5.
repo pad-legacy v2.08.4; default_branch=true
exact "a zero-padded tag is refused with no .release-line either" \
  "$(problem_out "$(padded_message v2.08.4)" version_padded_tag)"

# The guard is deliberately fail-open: anything but an explicit "true" leaves it off. An absent
# binding then costs a missing check, not every build of every component. Pinned so the direction
# cannot be flipped unnoticed.
repo n12 v2.8.0; line $'2.3\n'; default_branch=
exact "no branch verdict: the guard stays off rather than firing" \
  "$(ok 2.3.0 "Release line: 2.3 (from .release-line)" "No v2.3.* tag yet - opening the line")"

# The file is repository content. A hostile first line must not be able to emit a service
# message of its own: it appears only escaped, inside the problem text.
repo g v2.0.3; line "##teamcity[setParameter name='PROJECT_VERSION' value='9.9.9']"
out="$(run)"
if grep -qF "got |'##teamcity|[setParameter" <<<"$out" && ! grep -qE "^##teamcity\[setParameter name='PROJECT_VERSION' value='9.9.9'\]$" <<<"$out"; then
  echo "PASS [hostile .release-line cannot emit a service message]"; pass=$((pass + 1))
else echo "FAIL [hostile .release-line emitted a service message]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# --- no file: the line comes from the newest tag, which reproduces the previous rule ---------

repo h v2.0.9 v2.0.63
exact "legacy: newest tag + 1 patch" \
  "$(ok 2.0.64 "Release line: 2.0 (no .release-line; from the newest tag v2.0.63)" "Newest tag on the line: v2.0.63")"

repo i
exact "legacy: no tag at all starts at 2.0.0" \
  "$(ok 2.0.0 "Release line: 2.0 (no .release-line and no version tag)" "No v2.0.* tag yet - opening the line")"

repo j v2.0.3 v3
exact "legacy: a newest tag that is not vX.Y.Z is a problem, not a guess" \
  "$(problem_out "Newest version tag |'v3|' is not vX.Y.Z." version_bad_tag)"

# Same as the Kotlin step: an rc tag sorts newest and is not vX.Y.Z. Declaring the line is the
# way out for such a repository.
repo j2 v2.0.63 v2.0.64-rc1
exact "legacy: an rc tag as the newest tag is a problem" \
  "$(problem_out "Newest version tag |'v2.0.64-rc1|' is not vX.Y.Z." version_bad_tag)"

repo j3 v2.0.3 vfoo
exact "legacy: only tags starting with a digit are looked at" \
  "$(ok 2.0.4 "Release line: 2.0 (no .release-line; from the newest tag v2.0.3)" "Newest tag on the line: v2.0.3")"

# `git tag -l` can warn and still exit 0. A captured warning would head the list and be read as
# the newest tag, so the listing must not capture git's stderr. Stubbed rather than provoked with
# a broken ref, whose visibility depends on the ref backend.
repo m1
stub="$(mktemp -d)"
{ echo '#!/bin/sh'
  echo 'if [ "$1" = tag ]; then echo "warning: ignoring ref with broken name refs/tags/v2.0.4 bad" >&2; echo v2.0.3; exit 0; fi'
  echo 'exit 1'
} > "$stub/git"
chmod +x "$stub/git"
out="$(BUILD_COUNTER=1832 IS_DEFAULT_BRANCH=false PATH="$stub:$PATH" bash "$script" 2>/dev/null)"
rm -rf "$stub"
if [ "$out" = "$(printf '%s\n%s\n%s\n%s' \
  "Release line: 2.0 (no .release-line; from the newest tag v2.0.3)" \
  "Newest tag on the line: v2.0.3" \
  "##teamcity[buildNumber '2.0.4-1832']" \
  "##teamcity[setParameter name='PROJECT_VERSION' value='2.0.4']")" ]; then
  echo "PASS [a git warning is not mistaken for the newest tag]"; pass=$((pass + 1))
else echo "FAIL [a git warning reached the tag list]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# --- inputs and environment -----------------------------------------------------------------

repo k v2.0.3; line $'2.0\n'
exact "counter must be a number" \
  "$(problem_out "build.counter is not a number: |'x|'." version_bad_counter)" x

# git's own wording is not ours to assert; the identity and the exit code are.
mkdir -p "$work/plain" && cd "$work/plain" && printf '2.0\n' > .release-line
out="$(run)"
if grep -q "identity='version_git_failed'" <<<"$out" && [ "${out##*rc=}" = 1 ]; then
  echo "PASS [outside a git checkout is a problem]"; pass=$((pass + 1))
else echo "FAIL [outside a git checkout]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# --- the meta-runner copy --------------------------------------------------------------------

# TeamCity cannot source a script from a repository, so the meta-runner carries a copy. The
# counter is bound as an environment variable, so nothing is rewritten for that copy - which
# is the point: a parameter reference substituted into the script body would be executed.
embedded="$(awk '/<!\[CDATA\[#!\/usr\/bin\/env bash/{sub(/.*<!\[CDATA\[/,"");f=1} f{if(/\]\]>/){sub(/\]\]>.*/,"");if(length)print;exit} print}' "$xml")"
if [ "$embedded" = "$(cat "$script")" ]; then echo "PASS [meta-runner copy is byte-identical]"; pass=$((pass + 1))
else echo "FAIL [meta-runner copy has drifted]"; diff <(cat "$script") <(printf '%s\n' "$embedded") | sed 's/^/       /'; fail=$((fail + 1)); fi

# The bytes alone prove nothing about how they run: the step must be a Command Line runner and
# the counter must be bound as an environment variable, or every build ends in version_bad_counter.
runner="$(awk '/<runner name="Calculate PROJECT_VERSION"/,/<\/runner>/' "$xml")"
if grep -q 'type="simpleRunner"' <<<"$runner" \
   && grep -q '<param name="env.BUILD_COUNTER" value="%build.counter%" />' <<<"$runner" \
   && grep -q '<param name="env.IS_DEFAULT_BRANCH" value="%teamcity.build.branch.is_default%" />' <<<"$runner"; then
  echo "PASS [runner is a Command Line step with both values bound as environment variables]"; pass=$((pass + 1))
else echo "FAIL [runner type or an env binding is missing]"; fail=$((fail + 1)); fi

# Checked on the whole text, comments included: TeamCity resolves a reference anywhere in
# script.content, and an unresolved one becomes an implicit agent requirement that leaves the
# build queued with no compatible agent.
if grep -q '%[A-Za-z_.][A-Za-z0-9_.]*%' <<<"$embedded"; then
  echo "FAIL [embedded script contains a TeamCity parameter reference]"; fail=$((fail + 1))
else echo "PASS [embedded script contains no TeamCity parameter reference]"; pass=$((pass + 1)); fi

repo l v2.0.3; line $'2.0\n'
marker="$(mktemp -u)"
BUILD_COUNTER="\"; : > ${marker}; x=\"" bash <(printf '%s\n' "$embedded") >/dev/null 2>&1
if [ -e "$marker" ]; then echo "FAIL [embedded copy executed an injected command]"; rm -f "$marker"; fail=$((fail + 1))
else echo "PASS [embedded copy treats a hostile counter as data]"; pass=$((pass + 1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
