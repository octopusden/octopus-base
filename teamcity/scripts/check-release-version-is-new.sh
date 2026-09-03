#!/usr/bin/env bash
# TeamCity step: "Check release version is new" (Command Line runner, replaces the Kotlin script).
#
# The two values arrive as ENVIRONMENT VARIABLES, never interpolated into this script's text.
# The meta-runner binds them as env.BUILD_NUMBER / env.LAST_RELEASE_VERSION. Substituting a
# TeamCity %PARAM% into the script body instead would execute whatever the value contains,
# BEFORE any line below runs - and BUILD_NUMBER comes from the first line of a release-log
# file, so the value is repository content. The two existing meta-runners in this directory
# pass values the same way, as kotlinArgs.
set -uo pipefail

build="${BUILD_NUMBER-}"; last="${LAST_RELEASE_VERSION-}"
# That first line may carry a CR: the release log can be committed CRLF. The sibling helper
# .github/scripts/release-log-has-version.sh strips CR for the same reason.
build="${build%$'\r'}"; last="${last%$'\r'}"

# TeamCity service-message values are single-quoted; ' | [ ] CR and newlines must be escaped
# or the message is silently mangled. This applies to the values ECHOED below just as much as
# to the ones in messages: a first line of "##teamcity[setParameter name='ALREADY_PROCESSED'
# ...]" would otherwise be parsed as a service message and set the very parameter this step
# exists to control, before validation ever looked at it.
esc() {
  local s=$1
  s=${s//|/||}; s=${s//$'\r'/|r}; s=${s//$'\n'/|n}; s=${s//\'/|\'}; s=${s//[/|[}; s=${s//]/|]}
  printf '%s' "$s"
}

# buildProblem alone only fills the build's problem list; the log gets no error-severity line.
# Emit both: the message macro puts the reason in the log, the problem marks the build and
# carries the identity used to filter or mute it.
problem() {
  printf "##teamcity[message text='%s' status='ERROR']\n" "$(esc "$1")"
  printf "##teamcity[buildProblem description='%s' identity='%s']\n" "$(esc "$1")" "$2"
  exit 1
}
ok() { printf "##teamcity[buildStatus text='%s']\n" "$(esc "$1")"; }

echo "buildNumber: $(esc "$build")"
echo "lastRelease: $(esc "$last")"

ver='^[0-9]+(\.[0-9]+)*$'
[[ "$build" =~ $ver ]] || problem "Release log first line is not a version: '${build}'. Nothing can be processed until the module file starts with a plain x.y.z line." "releaselog_bad_version"

# An empty LAST_RELEASE_VERSION is the legitimate INITIAL state, not junk: the template ships
# the parameter blank and nothing sets it until the first post-processing run does. Rejecting
# it would turn every new component's first post-processing red.
if [ -z "$last" ]; then
  echo "No previously processed version is recorded - processing ${build}."
  echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']"
  exit 0
fi
[[ "$last" =~ $ver ]] || problem "LAST_RELEASE_VERSION is not a version: '${last}'. Fix the project parameter." "releaselog_bad_lastrelease"

# Compared in bash rather than through `sort -V`. This script runs without `set -e`, and a
# command substitution inside `[ ]` throws away the exit status - so a sort that could not do
# -V returned nothing, the "went backwards" branch was skipped, and post-processing proceeded
# on a version OLDER than the last one. Silently. Both values are digits and dots by now.
# Missing trailing segments count as 0, so 2.0 and 2.0.0 are the same version.
newer() {
  local -a l r; local i n x y
  IFS=. read -ra l <<<"$1"; IFS=. read -ra r <<<"$2"
  n=${#l[@]}; [ "${#r[@]}" -gt "$n" ] && n=${#r[@]}
  for ((i = 0; i < n; i++)); do
    x=${l[i]:-0}; y=${r[i]:-0}
    (( 10#$x > 10#$y )) && return 0
    (( 10#$x < 10#$y )) && return 1
  done
  return 1
}

if newer "$build" "$last"; then
  echo "${build} is newer than ${last} - processing"
  echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']"
elif newer "$last" "$build"; then
  # The first line of the release log moved BACKWARDS. Step 1 takes the version from that
  # line, so this is the only automatic detector of a corrupted log.
  problem "Release log went backwards: first line is '${build}' but '${last}' was already processed. Expected the newest version first - an old version was prepended instead of inserted in order." "releaselog_regressed"
else
  # The ordinary outcome of any commit to the module file that adds no newer version:
  # a manual release-log repair, or a rerun. Nothing to process, and nothing wrong.
  ok "${build} already processed - nothing to do"
  echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='true']"
fi
