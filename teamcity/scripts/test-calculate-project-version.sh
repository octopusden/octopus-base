#!/usr/bin/env bash
# Behaviour of calculate-project-version.sh, plus proof that the copy embedded in
# teamcity.meta-runners/OctopusCalculateBuildParameters.xml has not drifted from it.
#
# Every case compares the COMPLETE output and exit code, not a grep: a suite of positive greps
# passes on an implementation that emits every service message on every path.
cd "$(dirname "$0")" || exit 1
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

# A run whose whole environment is given: the suite's own variables are removed first, so a case
# can say that nothing is set.
run_with() { # <VAR=value>... -> complete output + rc
  local out rc
  out="$(env -u BUILD_COUNTER -u IS_DEFAULT_BRANCH "$@" bash "$script" 2>&1)"; rc=$?
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

ok_n() { # <counter> <version> <lines...> -> the complete output of a successful run
  local n=$1 v=$2; shift 2
  printf '%s\n' "$@"
  printf "##teamcity[buildNumber '%s-%s']\n##teamcity[setParameter name='PROJECT_VERSION' value='%s']\nrc=0" "$v" "$n" "$v"
}
ok() { local v=$1; shift; ok_n 1832 "$v" "$@"; }   # <version> <lines...>, with the usual counter
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

# Each side of the trim on its own. The combined case above passes even when only one side
# works, and the leading side is the one a reader gets wrong: written with a single % instead
# of %%, `${line#"${line%[![:space:]]*}"}` turns 2.1 into 1 rather than leaving it alone.
repo e3 v2.1.4; line $'  2.1\n'
exact "leading blanks alone are trimmed, and nothing else is" \
  "$(ok 2.1.5 "Release line: 2.1 (from .release-line)" "Newest tag on the line: v2.1.4")"

repo e4 v2.1.4; line $'2.1   \n'
exact "trailing blanks alone are trimmed" \
  "$(ok 2.1.5 "Release line: 2.1 (from .release-line)" "Newest tag on the line: v2.1.4")"

repo e5 v2.1.4; line $'\t2.1\t\n'
exact "tabs count as blanks on both sides" \
  "$(ok 2.1.5 "Release line: 2.1 (from .release-line)" "Newest tag on the line: v2.1.4")"

# A line of nothing but blanks trims to empty, which the format check then refuses by name.
repo e6 v2.1.4; line $'   \n'
exact "a line of blanks is refused, not silently treated as a line" \
  "$(problem_out ".release-line must hold major.minor on its first line, got |'|'." releaseline_bad_format)"

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

# This case used to pin the OPPOSITE direction - a missing verdict left the guard off, on the
# reasoning that an absent binding should cost a check rather than every build. That was wrong:
# the guard exists to stop a version from being tagged and published, so leaving it off silently
# publishes the very version it was there to catch. A missing verdict now stops the build, and
# the build that stops says which declaration is missing.
repo n12 v2.8.0; line $'2.3\n'; default_branch=
exact "no branch verdict: the build stops rather than publishing unguarded" \
  "$(problem_out "teamcity.build.branch.is_default is not true or false: |'|'. The meta-runner declares env.IS_DEFAULT_BRANCH among its own parameters - re-upload this server|'s copy if it predates that." version_bad_is_default)"

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

repo h2 v2.0.9 v2.0.63 v1.9.99
exact "legacy: the line comes from the first tag of the listing, not the last" \
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
  echo 'if [ "$1" = rev-parse ]; then pwd; exit 0; fi'
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

# The file belongs to the repository, not to whatever directory the step happens to run in.
# `git tag` finds the repository from anywhere, so without this the build would quietly fall back
# to deriving the line from tags - here, the 2.5.1 that declaring 2.4 exists to avoid.
repo w1 v2.4.1 v2.5.0; line $'2.4\n'; mkdir -p sub && cd sub || exit 1
exact "the file is read from the repository root, not the working directory" \
  "$(ok 2.4.2 "Release line: 2.4 (from .release-line)" "Newest tag on the line: v2.4.1")"

# An arithmetic result that wrapped must not be published as a version.
repo w2 v2.0.9223372036854775807; line $'2.0\n'
exact "a patch that overflows is refused, not published" \
  "$(printf '%s\n%s\n%s' "Release line: 2.0 (from .release-line)" \
     "Newest tag on the line: v2.0.9223372036854775807" \
     "$(problem_out "Computed version |'2.0.-9223372036854775808|' is not X.Y.Z." version_bad_result)")"

# --- inputs and environment -----------------------------------------------------------------

repo k v2.0.3; line $'2.0\n'
exact "counter must be a number" \
  "$(problem_out "build.counter is not a number: |'x|'." version_bad_counter)" x

exact "counter must not be empty" \
  "$(problem_out "build.counter is not a number: |'|'." version_bad_counter)" ""

# The counter is echoed back inside its own rejection, so every escaping rule has a reachable
# input. An unescaped one truncates or splits the reason an operator reads.
for ch in '|' "'" '[' ']'; do
  out="$(run "1${ch}")"
  if grep -qF "build.counter is not a number: |'1|${ch}|'." <<<"$out"; then
    echo "PASS [escapes '${ch}']"; pass=$((pass + 1))
  else echo "FAIL [does not escape '${ch}']"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
done
# Built with ANSI-C quoting, not command substitution, which strips a trailing newline.
cr=$'\r'; nl=$'\n'
for pair in "${cr}|r" "${nl}|n"; do
  out="$(run "1${pair%|*}x")"
  if grep -qF "build.counter is not a number: |'1|${pair#*|}x|'." <<<"$out"; then
    echo "PASS [escapes the ${pair#*|} control character]"; pass=$((pass + 1))
  else echo "FAIL [does not escape ${pair#*|}]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi
done

# git's own wording is not ours to assert; the identity and the exit code are.
mkdir -p "$work/plain" && cd "$work/plain" && printf '2.0\n' > .release-line
out="$(run)"
if grep -q "identity='version_git_failed'" <<<"$out" && [ "${out##*rc=}" = 1 ]; then
  echo "PASS [outside a git checkout is a problem]"; pass=$((pass + 1))
else echo "FAIL [outside a git checkout]"; sed 's/^/       /' <<<"$out"; fail=$((fail + 1)); fi

# --- where the two values come from ------------------------------------------------------------

# TeamCity delivers a value as an environment variable only when it is a BUILD parameter named
# env.X, declared by the meta-runner itself. The same name inside the <runner> block is an unknown
# runner setting that never reaches the process, which is how the first server to receive this
# meta-runner stopped every hybrid build on an empty counter. is_default is checked as strictly as
# the counter: it decides whether the backwards guard applies, so an absent or misspelled value
# must stop the build rather than quietly disable the guard.

repo m1 v2.5.1; line $'2.0\n'
exact_with "is_default absent: the build stops instead of skipping the guard" \
  "$(problem_out "teamcity.build.branch.is_default is not true or false: |'|'. The meta-runner declares env.IS_DEFAULT_BRANCH among its own parameters - re-upload this server|'s copy if it predates that." version_bad_is_default)" \
  BUILD_COUNTER=1832

repo m2 v2.5.1; line $'2.0\n'
exact_with "is_default empty: same" \
  "$(problem_out "teamcity.build.branch.is_default is not true or false: |'|'. The meta-runner declares env.IS_DEFAULT_BRANCH among its own parameters - re-upload this server|'s copy if it predates that." version_bad_is_default)" \
  BUILD_COUNTER=1832 IS_DEFAULT_BRANCH=""

repo m3 v2.5.1; line $'2.0\n'
exact_with "is_default True: not the same string, and not trusted to mean it" \
  "$(problem_out "teamcity.build.branch.is_default is not true or false: |'True|'. The meta-runner declares env.IS_DEFAULT_BRANCH among its own parameters - re-upload this server|'s copy if it predates that." version_bad_is_default)" \
  BUILD_COUNTER=1832 IS_DEFAULT_BRANCH=True

repo m4 v2.5.1; line $'2.0\n'
exact_with "is_default with a trailing blank: refused rather than trimmed" \
  "$(problem_out "teamcity.build.branch.is_default is not true or false: |'true |'. The meta-runner declares env.IS_DEFAULT_BRANCH among its own parameters - re-upload this server|'s copy if it predates that." version_bad_is_default)" \
  BUILD_COUNTER=1832 IS_DEFAULT_BRANCH="true "

# false is what a non-default branch actually gets, so it must stay ordinary.
repo m5 v2.0.3; line $'2.0\n'
exact_with "false is a value, not a missing binding" \
  "$(ok 2.0.4 "Release line: 2.0 (from .release-line)" "Newest tag on the line: v2.0.3")" \
  BUILD_COUNTER=1832 IS_DEFAULT_BRANCH=false

# --- the meta-runner copy --------------------------------------------------------------------

# TeamCity cannot source a script from a repository, so the meta-runner carries a copy. The
# counter is bound as an environment variable, so no VALUE is rewritten into that copy - which
# is the point: a parameter reference substituted into the script body would be executed.
#
# The copy is not byte-for-byte: TeamCity collapses every %% in script.content to one %, so the
# XML carries this file with every % doubled and the comparison escapes the source the same way.
# Why, and what it broke: docs/adr/0009-meta-runner-scripts-are-bash-on-posix-agents.md
#
#   regenerate with: sed 's/%/%%/g' teamcity/scripts/calculate-project-version.sh
#   and replace the text between the CDATA markers of the script.content param with the result.
# Extracted to a file, not into a variable: $(...) strips trailing newlines, so blank lines
# added before ]]> vanished at capture time and no comparison downstream could see them.
awk '/<!\[CDATA\[#!\/usr\/bin\/env bash/{sub(/.*<!\[CDATA\[/,"");f=1} f{if(/\]\]>/){sub(/\]\]>.*/,"");if(length)print;exit} print}' "$xml" > "$work/embedded"
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

# The bytes alone prove nothing about how they run: the step must be a Command Line runner that
# runs this script and reports its stderr.
runner="$(awk '/<runner name="Calculate PROJECT_VERSION"/,/<\/runner>/' "$xml")"
if grep -q 'type="simpleRunner"' <<<"$runner" \
   && grep -q '<param name="use.custom.script" value="true" />' <<<"$runner" \
   && grep -q '<param name="log.stderr.as.errors" value="true" />' <<<"$runner"; then
  echo "PASS [runner is a Command Line step that runs this script with stderr at error severity]"; pass=$((pass + 1))
else echo "FAIL [runner type, script mode or stderr mode is missing]"; fail=$((fail + 1)); fi

# An env. parameter is a BUILD parameter. Declared inside the runner it is an unknown runner
# setting, which TeamCity ignores without a word - the whole defect. Declared in the meta-runner's
# own parameters it reaches the process.
if grep -q 'name="env\.' <<<"$runner"; then
  echo "FAIL [runner declares an env. parameter, which the runner ignores]"; fail=$((fail + 1))
else echo "PASS [no env. parameter is buried in the runner block]"; pass=$((pass + 1)); fi

settings="$(awk '/<settings>/,/<build-runners>/' "$xml")"
if grep -q '<param name="env.BUILD_COUNTER" value="%build.counter%"/>' <<<"$settings" \
   && grep -q '<param name="env.IS_DEFAULT_BRANCH" value="%teamcity.build.branch.is_default%"/>' <<<"$settings"; then
  echo "PASS [both values are declared as meta-runner env. parameters]"; pass=$((pass + 1))
else echo "FAIL [a meta-runner env. parameter declaration is missing]"; fail=$((fail + 1)); fi

# A bash script in a Command Line runner cannot run on a Windows agent at all: TeamCity writes
# it as a .cmd and cmd.exe reads the shebang as a command name. The runner must say so itself -
# a requirement added to one build configuration does nothing for the other 37 that use it.
#
# Read from inside <requirements> with comments removed, and asserted attribute by attribute.
# Greping the whole file passed on the element commented out - which is how someone will disable
# it to force a build onto one agent - and on the block moved outside <settings>, where TeamCity
# ignores it. Matching the attributes in a fixed order instead went red on id/name swapped, which
# is valid XML and what a round-trip through the server can produce: a suite that fails on
# correct input gets "fixed" by editing the input.
requirements="$(perl -0777 -ne 's/<!--.*?-->//gs; print $1 if m{<settings>.*(<requirements\b.*?(?:/>|</requirements>)).*</settings>}s' "$xml")"
if grep -q 'does-not-contain' <<<"$requirements" \
   && grep -q 'name="teamcity.agent.jvm.os.name"' <<<"$requirements" \
   && grep -q 'value="Windows"' <<<"$requirements"; then
  echo "PASS [runner refuses Windows agents, where its script cannot run]"; pass=$((pass + 1))
else echo "FAIL [runner does not exclude Windows agents]"; fail=$((fail + 1)); fi

repo l v2.0.3; line $'2.0\n'
marker="$(mktemp -u)"
BUILD_COUNTER="\"; : > ${marker}; x=\"" bash <(printf '%s\n' "$embedded" | sed 's/%%/%/g') >/dev/null 2>&1
if [ -e "$marker" ]; then echo "FAIL [embedded copy executed an injected command]"; rm -f "$marker"; fail=$((fail + 1))
else echo "PASS [embedded copy treats a hostile counter as data]"; pass=$((pass + 1)); fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
