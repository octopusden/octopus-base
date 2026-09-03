#!/usr/bin/env bash
#
# One question, asked the same way by everyone who asks it: does Maven Central hold
# <group>:<artifact> at <version>?
#
# Sourced, not executed. It exists because two callers need the probe and their VERDICTS are
# opposites: the release preflight fails open, because it can only ever save a build that was
# going to fail anyway, while the #189 recovery fails closed, because it writes tags and
# release-log entries. Sharing the verdict would be wrong; sharing the request is not, and the
# URL construction below has a subtlety that must not be re-derived in a second copy.
#
# repo1_coordinate_state <group:artifact> <version>
#   prints: present | absent | unknown
#
# `unknown` is not a soft `absent`. A 5xx, a rate limit, a proxy error and a dropped connection
# all look alike here, and none of them is evidence about the version. What a caller does with
# that is the caller's decision.
#
# Overridable by the caller before sourcing or calling:
#   REPO1_BASE   default https://repo1.maven.org/maven2
#   REPO1_NET    curl options as an array; default HEAD with short ceilings, because only the
#                status code is read and the requests are serial

REPO1_BASE="${REPO1_BASE:-https://repo1.maven.org/maven2}"
# `${VAR+x}` rather than `${#VAR[@]}`: the latter is an error on an unset array under `set -u`
# in bash 3.2, which is what a developer running the scenario suites on a Mac has.
if [ -z "${REPO1_NET+x}" ]; then
  REPO1_NET=(-sS --head --connect-timeout 10 --max-time 20)
fi

repo1_coordinate_state() {
  local ga="$1" version="$2" grp art url code
  grp="${ga%%:*}"; art="${ga##*:}"
  # ${grp//.//} rather than ${grp//./\/}: a backslash-escaped replacement is stripped by bash 5
  # but kept literally by bash 3.2, which would build .../org\/octopusden/... and 404 every
  # coordinate. This form means the same thing to every bash.
  url="$REPO1_BASE/${grp//.//}/$art/$version/$art-$version.pom"
  code=$(curl "${REPO1_NET[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
  case "$code" in
    200) printf 'present\n' ;;
    404) printf 'absent\n' ;;
    *)   printf 'unknown\n' ;;
  esac
}
