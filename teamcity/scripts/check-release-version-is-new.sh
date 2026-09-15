#!/usr/bin/env bash
# TeamCity step: "Check release version is new" (Command Line runner, replaces the Kotlin script).
#
# The two values are never interpolated into this script's text. Substituting a TeamCity
# parameter reference into the script body would execute whatever the value contains, BEFORE any
# line below runs - and BUILD_NUMBER comes from the first line of a release-log file, so the
# value is repository content. They arrive as environment variables the meta-runner declares, or
# from the agent's build properties file when it does not - see the lookup below.

build="${BUILD_NUMBER-}"; last="${LAST_RELEASE_VERSION-}"

# A value reaches a step as an environment variable only when it is a BUILD parameter named
# env.X, which the meta-runner declares in its own parameters. The same name inside the runner
# block is an unknown runner SETTING, ignored without a word - and here that would not even fail
# loudly: an empty LAST_RELEASE_VERSION is the legitimate initial state below, so every release
# would look like the first one and this step would pass while checking nothing. Both values are
# therefore also read from the properties file the agent writes for every step and names in
# TEAMCITY_BUILD_PROPERTIES_FILE. Configuration parameters may live in the second file that one
# names instead. What the files hold is data: read with `read`, never evaluated.
# Two sources for one value is deliberate but temporary: TD-008.
prop_files=()
[ -f "${TEAMCITY_BUILD_PROPERTIES_FILE-}" ] && prop_files=("$TEAMCITY_BUILD_PROPERTIES_FILE")
prop() { # <key> -> the last value the files give it, empty when absent
  local key=$1 f entry value=
  for f in ${prop_files+"${prop_files[@]}"}; do
    while IFS= read -r entry || [ -n "$entry" ]; do
      [ "${entry%%=*}" = "$key" ] || continue
      value=${entry#*=}
    done < "$f"
  done
  printf '%s' "$value"
}
config_props="$(prop teamcity.configuration.properties.file)"
[ -n "$config_props" ] && [ -f "$config_props" ] && prop_files+=("$config_props")

[ -n "$build" ] || build="$(prop build.number)"
[ -n "$last" ] || last="$(prop LAST_RELEASE_VERSION)"

build="${build%$'\r'}"; last="${last%$'\r'}"   # the release log can be committed CRLF

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

# Compared in bash, so no external command's failure can change the verdict: `sort -V` used
# to, silently. Segments are numeric by now; missing ones count as 0, so 2.0 equals 2.0.0.
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
  # Ordinary: a commit to the module file that added no newer version - a repair, or a rerun.
  printf "##teamcity[buildStatus text='%s']\n" "$(esc "${build} already processed - nothing to do")"
  echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='true']"
fi
