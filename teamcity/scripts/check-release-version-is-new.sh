#!/usr/bin/env bash
# TeamCity step: "Check release version is new" (Command Line runner, replaces the Kotlin script).
# Args: %build.number% %LAST_RELEASE_VERSION%
set -uo pipefail

build="${1-}"; last="${2-}"

# TeamCity service-message values are single-quoted; ' | [ ] and newlines must be escaped
# or the message is silently mangled and the build problem never appears.
esc() { local s=$1; s=${s//|/||}; s=${s//\'/|\'}; s=${s//$'\n'/|n}; s=${s//[/|[}; s=${s//]/|]}; printf '%s' "$s"; }
# buildProblem alone only fills the build's problem list; the log gets no error-severity
# line, so `log.stderr.as.errors` on the neighbouring step has no equivalent here. Emit both:
# the message macro puts the reason in the log, the problem marks the build and carries the
# identity used to filter or mute it.
problem() {
  printf "##teamcity[message text='%s' status='ERROR']\n" "$(esc "$1")"
  printf "##teamcity[buildProblem description='%s' identity='%s']\n" "$(esc "$1")" "$2"
  exit 1
}
ok()      { printf "##teamcity[buildStatus text='%s']\n" "$(esc "$1")"; }

echo "buildNumber: ${build}"
echo "lastRelease: ${last}"

# Both values are compared as versions, so refuse anything that is not one rather than
# letting a comparison silently order it. build comes from `head -n 1 <module>.txt`, so an
# empty or corrupt first line lands here.
ver='^[0-9]+(\.[0-9]+)*$'
[[ "$build" =~ $ver ]] || problem "Release log first line is not a version: '${build}'. Nothing can be processed until the module file starts with a plain x.y.z line." "releaselog_bad_version"
[[ "$last"  =~ $ver ]] || problem "LAST_RELEASE_VERSION is not a version: '${last}'. Fix the project parameter." "releaselog_bad_lastrelease"

if [ "$build" = "$last" ]; then
  # The ordinary outcome of any commit to the module file that did not add a newer version:
  # a manual repair, or a rerun. Nothing to process, and nothing wrong.
  ok "${build} already processed - nothing to do"
  echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='true']"
  exit 0
fi

# Strictly older means the first line of the release log moved BACKWARDS. Step 1 takes the
# version from that line, so this is the only automatic detector of a corrupted log.
if [ "$(printf '%s\n%s\n' "$build" "$last" | sort -V | tail -n1)" = "$last" ]; then
  problem "Release log went backwards: first line is '${build}' but '${last}' was already processed. Expected the newest version first - an old version was prepended instead of inserted in order." "releaselog_regressed"
fi

echo "${build} is newer than ${last} - processing"
echo "##teamcity[setParameter name='ALREADY_PROCESSED' value='false']"
