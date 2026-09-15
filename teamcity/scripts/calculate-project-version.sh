#!/usr/bin/env bash
# TeamCity step: "Calculate PROJECT_VERSION" (Command Line runner, replaces the Kotlin script).
#
# major.minor comes from the first line of `.release-line` in the repository root; the patch is
# the newest vmajor.minor.N tag on that line plus one, or 0 when the line has none. On the
# default branch the line may not be behind the newest release, which catches the typo that
# would otherwise be tagged and published before anything noticed. Without the file the line is
# taken from the newest v-tag instead (2.0 when there is none), which is the previous rule and
# lets the meta-runner be re-uploaded before every repository carries the file. Why the version
# is decided here, in the first build of the chain, and not later:
# docs/adr/0008-release-line-is-declared-in-the-repository.md.
#
# BUILD_COUNTER and IS_DEFAULT_BRANCH arrive as ENVIRONMENT VARIABLES, never interpolated into
# this script's text. A TeamCity parameter reference substituted into the script body is
# executed, not read - see OctopusCheckReleaseVersionIsNew.xml, which binds its values the same
# way. The reference syntax itself is also kept out of this file: TeamCity resolves it inside
# script.content wherever it appears, comments included, and an unresolved one is an implicit
# agent requirement.

counter="${BUILD_COUNTER-}"
file=.release-line

# TeamCity service-message values are single-quoted; ' | [ ] CR and newlines must be escaped
# or the message is silently mangled. The release-line file is repository content, so what it
# holds is echoed only through esc().
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

[[ "$counter" =~ ^[0-9]+$ ]] || problem "build.counter is not a number: '${counter}'." "version_bad_counter"

# Everything below is relative to the repository root. `git tag` finds the repository from any
# directory but `[ -f .release-line ]` does not, so a step given a working directory below the
# root would silently miss the file and fall back to deriving the line from tags - which for a
# maintenance branch is the exact version it declared the line to avoid.
root="$(git rev-parse --show-toplevel)" || problem "git rev-parse failed; is this a git checkout? Its error is in the log above." "version_git_failed"
cd "$root" || problem "Cannot enter the repository root '${root}'." "version_git_failed"

# One listing serves all three uses below: the line's newest patch, the legacy line, and the
# guard's newest release.
#
# A zero-padded component is refused outright before any of that (see below), which is what lets
# the searches below take the first match on git's order: for tags with no leading zeros, that
# order IS the numeric one.
#
# git's stderr is deliberately NOT captured. `git tag -l` warns and still exits 0 - a ref with a
# broken name is enough - and a captured warning becomes the first line of the list, which the
# legacy branch below reads as the newest tag. The warning belongs in the build log, which
# log.stderr.as.errors already surfaces.
tags="$(git tag -l --sort=-v:refname 'v[0-9]*')" || problem "git tag failed while listing version tags; its error is in the log above." "version_git_failed"

# v2.08.4 is the same release as v2.8.4 to every numeric comparison downstream, a different string
# to a text search, and sorts by neither rule in git. One ambiguous tag therefore reaches this
# calculation three different ways - it hid a higher release from the backwards check, it took a
# patch number that was already used, and adopting a line reset that line's patch to 0. The shape
# is refused here instead of being handled three times. No repository in the organisation has one.
while IFS= read -r tag; do
  [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
  for component in "${BASH_REMATCH[@]:1}"; do
    [[ "$component" =~ ^0[0-9] ]] || continue
    problem "Version tag '${tag}' has a zero-padded component; a release tag must be vX.Y.Z with no leading zeros. Delete it or re-create it unpadded." "version_padded_tag"
  done
done <<<"$tags"

if [ -f "$file" ]; then
  # `read` takes the first line and nothing else; it returns 1 on a file without a trailing
  # newline, with the line already assigned. The CR of a CRLF file and any blanks around the
  # value come off here rather than through IFS: whether `read` strips a TRAILING non-whitespace
  # IFS delimiter differs between bash versions (5.2.21 on the runner keeps it, 5.3.15 on a
  # laptop removes it), which is not a difference to depend on. A CR counts as [:space:], so the
  # trailing trim takes it off. Leading zeros are refused: 2.05 would be a line of its own here
  # and the same version as 2.5 downstream.
  IFS= read -r line < "$file" || true
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ "$line" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || problem "${file} must hold major.minor on its first line, got '${line}'." "releaseline_bad_format"
  echo "Release line: ${line} (from ${file})"

  # A line behind what is already released would be tagged, published and registered before the
  # post-processing version check stopped it, so it is refused here, where nothing exists yet.
  # Only on the default branch: a maintenance branch declaring an older line is the case the
  # file exists for. Anything but an explicit "true" leaves the check off. That is not about an
  # unresolved parameter reference - such a build never starts, so this script never runs - but
  # about the server's own copy of the meta-runner, which is uploaded by hand and can lose the
  # binding without anything here noticing. Tags that are not releases are skipped, so
  # an rc tag left on the newest commit cannot make a current line look behind; the first release
  # tag in the list is then the highest one, padding being refused above.
  if [ "${IS_DEFAULT_BRANCH-}" = true ]; then
    IFS=. read -r major minor <<<"$line"
    while IFS= read -r tag; do
      [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || continue
      if (( major < ${BASH_REMATCH[1]} ||
            (major == ${BASH_REMATCH[1]} && minor < ${BASH_REMATCH[2]}) )); then
        problem "${file} declares ${line} but ${tag} is already released; on the default branch the line cannot go backwards." "releaseline_behind"
      fi
      break
    done <<<"$tags"
  fi
else
  tag="${tags%%$'\n'*}"
  if [ -z "$tag" ]; then
    line=2.0
    echo "Release line: ${line} (no ${file} and no version tag)"
  else
    [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || problem "Newest version tag '${tag}' is not vX.Y.Z." "version_bad_tag"
    line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    echo "Release line: ${line} (no ${file}; from the newest tag ${tag})"
  fi
fi

# Highest patch on the line: the first match in the list, padding being refused above. The regex
# is what admits a tag - v2.0.6.1 and v2.0.64-rc1 are not on line 2.0.
patch=
while IFS= read -r tag; do
  [[ "$tag" =~ ^v${line//./\\.}\.([0-9]+)$ ]] && { patch=${BASH_REMATCH[1]}; break; }
done <<<"$tags"
if [ -z "$patch" ]; then
  echo "No v${line}.* tag yet - opening the line"
  version="${line}.0"
else
  echo "Newest tag on the line: v${line}.${patch}"
  version="${line}.$((patch + 1))"
fi

# Nothing above can produce a version that is not X.Y.Z - unless an arithmetic result wrapped,
# which a patch past 2^63 does, turning into a negative number that would otherwise be published.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problem "Computed version '${version}' is not X.Y.Z." "version_bad_result"

echo "##teamcity[buildNumber '${version}-${counter}']"
echo "##teamcity[setParameter name='PROJECT_VERSION' value='${version}']"
