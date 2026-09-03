#!/usr/bin/env bash
#
# Finish our record of a version Maven Central has already accepted: the tag, the GitHub Release,
# and the octopus-release-log entry (octopus-base#189).
#
# Run by an operator from an octopus-base checkout, under their own `gh` credential. It plans by
# default and writes only with --apply:
#
#   recover-release.sh <owner/repo> <version> <built-sha> <group:artifact>[,...]
#   recover-release.sh <owner/repo> <version> <built-sha> <group:artifact>[,...] --apply
#
# It never publishes anything. The artifacts are immutable and Central refuses a coordinate that
# exists, so there is nothing to repeat — only a record to finish. Four facts are established, and
# the writes happen in the order they depend on each other:
#
#   1. Central holds every named coordinate at this version.
#   2. The tag points at the commit that was built.
#   3. The GitHub Release exists, is not a draft, and is attached to that tag.
#   4. octopus-release-log records the version, in a position that keeps the file ordered.
#
# THE EXIT CODE IS THE POINT. This exits non-zero while any of those is unfinished, which
# deliberately diverges from ADR 0001's fail-open registration: failing open is right on the
# release path, where the alternative is blocking a release over bookkeeping, and wrong here, where
# the bookkeeping IS the deliverable. octopus-sonar-automation 2.0.15 was recovered by hand with
# the tag and the release created and the log entry forgotten for four days, and nothing was red,
# because the two completed steps reported success and the third had no marker attached to it.
#
# Why the credential is the operator's own, and not a provisioned one: creating a tag on a commit
# that carries workflow files needs `workflow` scope, which the Actions GITHUB_TOKEN can never
# have (#180). The token `gh auth login` mints through its OAuth flow does have it. See ADR 0009
# for what that costs — one credential instead of a read/write split, and no run in Actions.
#
# Inputs (env, all optional):
#   RELEASE_LOG_REPO  default octopusden/octopus-release-log
#   RELEASE_LOG_REF   branch to write the log entry on, default main
#   REPO1_BASE, REPO1_NET  as repo1-coordinate.sh documents
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/repo1-coordinate.sh"

RELEASE_LOG_REPO="${RELEASE_LOG_REPO:-octopusden/octopus-release-log}"
RELEASE_LOG_REF="${RELEASE_LOG_REF:-main}"

note()   { printf '%s\n' "$*" >&2; }
refuse() { printf 'REFUSED: %s\n%s\n' "$1" "$2" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  recover-release.sh <owner/repo> <version> <built-sha> <group:artifact>[,<group:artifact>...] [--apply]

Plans by default and writes nothing. --apply re-reads every fact and then writes.

  <built-sha>  the commit the failed run BUILT, as 40 hex characters. It is the "Built commit"
               annotation on that run's page; the branch head is usually NOT it, and on a resumed
               run that annotation points at the earlier run instead.
  coordinates  what the publish sent, as group:artifact. The failed run's log names them: the
               Central preflight block "Publications this release would publish" for a Gradle
               release, the "Uploading to" lines of `mvn deploy` for a Maven one, and the
               "Deployment coordinates" block for octopus-base's own release.
EOF
  exit 2
}

# ---------------------------------------------------------------------------
# Arguments. Validated before anything reaches an API, because these values are
# interpolated into request paths.
# ---------------------------------------------------------------------------
APPLY=false
declare -a positional=()
for arg in "$@"; do
  case "$arg" in
    --apply)     APPLY=true ;;
    -h|--help)   usage ;;
    -*)          refuse "Unknown option" "'${arg}' is not an option this takes. The only one is --apply." ;;
    *)           positional+=("$arg") ;;
  esac
done
[ "${#positional[@]}" -eq 4 ] || usage

TARGET_REPO="${positional[0]}"
VERSION="${positional[1]}"
COMMIT="${positional[2]}"
COORDINATES="${positional[3]}"
TAG="v${VERSION}"
MODULE="${TARGET_REPO##*/}"   # the log's file name is the repository name, `octopus-` prefix included

[[ "$TARGET_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || refuse "Unusable repository" "'${TARGET_REPO}' is not owner/repo."
# Strict X.Y.Z. The registration path accepts more than this, but every line in every module file
# of the release log is X.Y.Z, and the insertion below compares those as three numbers. A version
# outside that shape would be placed by a comparison that was never designed for it.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || refuse "Unusable version" "'${VERSION}' is not an X.Y.Z version. Every line in the release log is, and this inserts by comparing those three numbers. Record such a version by hand."
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || refuse "Unusable commit" "'${COMMIT}' is not a full 40-character commit SHA. A short SHA is refused rather than resolved: the whole point of this argument is to name one commit unambiguously."

declare -a coords=()
add_coord() {
  local c="$1"
  c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
  [ -n "$c" ] || return 0
  # No leading hyphen: these are interpolated into a URL and passed as arguments downstream.
  [[ "$c" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*:[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]] \
    || refuse "Unusable coordinate" "'${c}' is not a group:artifact coordinate."
  local existing
  for existing in ${coords[@]+"${coords[@]}"}; do [ "$existing" = "$c" ] && return 0; done
  coords+=("$c")
}
while IFS= read -r line; do add_coord "$line"; done <<<"${COORDINATES//,/$'\n'}"
[ "${#coords[@]}" -gt 0 ] || refuse "No coordinates" "Nothing says which coordinates ${VERSION} published, and asking Central is the one check this may not skip."

# ---------------------------------------------------------------------------
# The tools this needs. A missing one must stop the run, not corrupt a ledger halfway.
# ---------------------------------------------------------------------------
command -v gh >/dev/null 2>&1 || refuse "gh is not installed" "This drives the GitHub API through gh."
command -v jq >/dev/null 2>&1 || refuse "jq is not installed" "Responses are read with jq."
command -v curl >/dev/null 2>&1 || refuse "curl is not installed" "The Central probe uses curl."
auth="$(gh auth status 2>&1)" \
  || refuse "gh is not authenticated" "Run \`gh auth login\` first. $(printf '%s' "$auth" | head -3)"
# The scope that matters is `workflow`: without it GitHub refuses to create a tag on a commit that
# touches .github/workflows (#180), which is a state a release regularly reaches. Only classic and
# OAuth tokens report scopes; a fine-grained token expresses the same thing as a `Workflows`
# permission that `gh auth status` cannot show, so say so rather than refusing a working credential.
if printf '%s' "$auth" | grep -q 'Token scopes:'; then
  printf '%s' "$auth" | grep 'Token scopes:' | grep -q "'workflow'" \
    || refuse "Credential cannot modify workflows" "This token's scopes do not include 'workflow', so GitHub will refuse to create ${TAG} if ${COMMIT} touches a workflow file (#180) — after the other ledgers have been written. Re-authenticate with \`gh auth refresh -s workflow\`."
else
  note "NOTE: this credential does not report scopes (a fine-grained token). It needs Contents: write and Workflows: write on ${TARGET_REPO}; if it lacks the latter, creating the tag fails with a masked 404 (#180)."
fi

# Where this code came from. An org-wide credential is about to run it, so an uncommitted local
# edit is worth seeing in the record rather than discovering afterwards.
self_sha="$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
self_dirty=""
git -C "$here" diff --quiet HEAD -- "$here" 2>/dev/null || self_dirty=" (with uncommitted changes)"

cat >&2 <<EOF

  ${APPLY:+}$([ "$APPLY" = true ] && echo APPLY || echo PLAN) — recovering ${MODULE} ${VERSION}
  actor        $(gh api user --jq '.login' 2>/dev/null || echo unknown)
  target       ${TARGET_REPO} @ ${COMMIT}
  tag/release  ${TAG}
  coordinates  ${coords[*]}
  release log  ${RELEASE_LOG_REPO}/${MODULE}.txt on ${RELEASE_LOG_REF}
  reconciler   ${self_sha}${self_dirty}

EOF

# ---------------------------------------------------------------------------
# Fact 1 — the commit exists, and where it sits
# ---------------------------------------------------------------------------
gh api "repos/${TARGET_REPO}/commits/${COMMIT}" --jq '.sha' >/dev/null 2>&1 \
  || refuse "Commit not found" "${TARGET_REPO} has no commit ${COMMIT}, or it could not be read. Refusing to tag a commit that cannot be confirmed to exist."

# Reported, never gated. Central proves the artifacts exist; nothing proves they came from this
# commit, so the commit is the operator's attestation either way — and a squash-merged release
# branch that has since been deleted leaves a commit no branch reaches, which is legitimate.
default_branch="$(gh api "repos/${TARGET_REPO}" --jq '.default_branch' 2>/dev/null || true)"
commit_position="not compared"
if [ -n "$default_branch" ]; then
  case "$(gh api "repos/${TARGET_REPO}/compare/${default_branch}...${COMMIT}" --jq '.status' 2>/dev/null || true)" in
    identical) commit_position="is the head of ${default_branch}" ;;
    behind)    commit_position="is an ancestor of ${default_branch}" ;;
    ahead|diverged) commit_position="is NOT on ${default_branch} — expected if its branch was squash-merged or deleted; you are attesting it" ;;
    *)         commit_position="could not be compared with ${default_branch}" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Fact 2 — Maven Central. Fails closed, unlike the release preflight that shares this probe:
# that one can only ever save a build that was going to fail anyway, this one writes tags.
# ---------------------------------------------------------------------------
declare -a present=() absent=() unknown=()
for ga in "${coords[@]}"; do
  state="$(repo1_coordinate_state "$ga" "$VERSION")"
  note "  central: ${state}  ${ga}"
  case "$state" in
    present) present+=("$ga") ;;
    absent)  absent+=("$ga") ;;
    *)       unknown+=("$ga") ;;
  esac
done
if [ "${#unknown[@]}" -gt 0 ]; then
  refuse "Maven Central did not answer" "${#unknown[@]} of ${#coords[@]} coordinate(s) got neither a 200 nor a 404 (${unknown[*]}), so whether ${VERSION} is published is unknown. Re-run when repo1 is reachable."
fi
if [ "${#absent[@]}" -gt 0 ] && [ "${#present[@]}" -eq 0 ]; then
  refuse "Version not published" "None of the ${#coords[@]} coordinate(s) are on Maven Central. This is not the #189 shape — that state has the artifacts published and only our record missing. Re-run the release instead of recovering it."
fi
if [ "${#absent[@]}" -gt 0 ]; then
  refuse "Version only partly published" "${#present[@]} of ${#coords[@]} coordinate(s) are on Maven Central and ${#absent[@]} are not (${absent[*]}). Neither recovering nor re-running this version can be right: Central refuses the coordinates that exist, so the missing ones can never join them. Release the next version, and record this one only if you decide the published half is what consumers should resolve."
fi

# ---------------------------------------------------------------------------
# Fact 3 — the tag, and Fact 4 — the release
# ---------------------------------------------------------------------------
tag_state="absent" tag_sha=""
if tag_sha="$(gh api "repos/${TARGET_REPO}/commits/${TAG}" --jq '.sha' 2>/dev/null)" && [ -n "$tag_sha" ]; then
  if [ "$tag_sha" = "$COMMIT" ]; then tag_state="at the commit"; else tag_state="at ${tag_sha}"; fi
fi
[ "$tag_state" = "absent" ] || [ "$tag_state" = "at the commit" ] \
  || refuse "Tag stands at another commit" "${TAG} already resolves to ${tag_sha}, not to ${COMMIT}. Nothing is moved: one of the two is wrong, and a tag that outlived its release is how a release ends up pointing at stale code. Resolve which commit was published before running this again."

# `gh release view`, not the REST lookup by tag: a draft is invisible to the latter, and a
# stranded draft is exactly one of the states this exists to end.
release_state="absent"
if rel="$(gh release view "$TAG" --repo "$TARGET_REPO" --json isDraft,tagName 2>&1)"; then
  if [ "$(jq -r '.isDraft' <<<"$rel" 2>/dev/null)" = "true" ]; then release_state="draft"; else release_state="published"; fi
elif ! grep -qE 'release not found|HTTP 404|"status": ?"404"' <<<"$rel"; then
  refuse "Release lookup failed" "Could not determine whether a release exists for ${TAG}: ${rel}. Refusing to act on unverified state."
fi

# ---------------------------------------------------------------------------
# Fact 5 — the release log. Read the whole file: the position matters, not only presence.
# ---------------------------------------------------------------------------
# The receiving workflow in octopus-release-log only ever PREPENDS, and its only trigger is a
# repository_dispatch. The first line of a module file is load-bearing: internal release
# post-processing triggers on a commit to that repository, takes its build number from
# `head -n 1 <module>.txt`, and refuses to run when its stored last-release value is already at
# least that. A recovery runs on a version that is by definition not always the newest — 2.0.15
# while 2.0.16 has shipped — so a dispatch would prepend a stale version and make post-processing
# compute the wrong version until the next real release. So this writes the file directly, by
# compare-and-swap on its blob sha, and inserts the version where the ordering already puts it.
version_le() { # <a> <b>  → true when a <= b, comparing X.Y.Z as three numbers
  local a="$1" b="$2"
  local a1="${a%%.*}" b1="${b%%.*}" ar br a2 b2 a3 b3
  ar="${a#*.}"; br="${b#*.}"
  a2="${ar%%.*}"; b2="${br%%.*}"
  a3="${ar#*.}"; b3="${br#*.}"
  [ "$a1" -ne "$b1" ] && { [ "$a1" -lt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -lt "$b2" ]; return; }
  [ "$a3" -le "$b3" ]
}

# Prints the blob sha on stdout and writes the decoded file to $1. Returning two values that way,
# rather than through a file descriptor, keeps the caller free of a temp file inside the working
# tree — this script runs from a checkout of octopus-base and must not litter it.
# rc 0 = read, rc 1 = unreadable, rc 2 = no such file.
log_read() { # <content-outfile>
  local out="$1" body sha encoded
  if ! body="$(gh api "repos/${RELEASE_LOG_REPO}/contents/${MODULE}.txt?ref=${RELEASE_LOG_REF}" 2>&1)"; then
    grep -qE 'HTTP 404|"status": ?"404"' <<<"$body" && return 2
    printf '%s\n' "$body" >&2
    return 1
  fi
  sha="$(jq -r '.sha' <<<"$body")"
  encoded="$(jq -r '.content' <<<"$body" | LC_ALL=C tr -d '\n')"
  # The same two guards the registration path documents: BSD base64 decodes a truncated payload
  # and reports success, so a syntax check has to come first or the outcome depends on which
  # coreutils is installed.
  [ -n "$encoded" ] && [ "$encoded" != "null" ] \
    && [ $(( ${#encoded} % 4 )) -eq 0 ] && [[ "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
    || { note "The release log for ${MODULE} could not be decoded."; return 1; }
  LC_ALL=C base64 -d <<<"$encoded" > "$out" 2>/dev/null || return 1
  printf '%s' "$sha"
}

declare -a log_lines=()
log_sha="" log_state="" log_position="" log_dups="" insert_at=""
log_rc=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log_sha="$(log_read "$WORK/log")" || log_rc=$?
if [ "$log_rc" -eq 2 ]; then
  log_state="no file yet"
  # The version becomes the only line, so it is also the first one: post-processing reads that.
  insert_at=0
elif [ "$log_rc" -ne 0 ]; then
  refuse "Release log unreadable" "${RELEASE_LOG_REPO}/${MODULE}.txt could not be read. Refusing to write on unverified state: the position of an entry in that file is what this is here to get right."
fi

if [ "$log_state" != "no file yet" ]; then
  # `|| [ -n "$line" ]` so a file whose last byte is not a newline does not lose its last line.
  # Every module file ends in one today, but that is a property of the data, not an invariant, and
  # dropping a version here would delete it from the log.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    log_lines+=("$line")
  done < "$WORK/log"
  # Every line has to be X.Y.Z, or the comparison that places the new one is meaningless.
  for i in "${!log_lines[@]}"; do
    [[ "${log_lines[$i]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || refuse "Release log has an unusable line" "${MODULE}.txt line $((i+1)) is '${log_lines[$i]}', not an X.Y.Z version. This inserts by comparing those three numbers, so it will not touch a file it cannot read. Fix that line by hand first."
  done
  # And the file has to be ordered already. Duplicates are NOT a defect: the receiving workflow
  # prepends unconditionally, so a repeated dispatch leaves two adjacent identical lines, and four
  # module files carry them today. Out-of-order lines are a different thing, and this refuses to
  # write over them rather than quietly repairing someone else's history.
  for (( i=1; i<${#log_lines[@]}; i++ )); do
    if ! version_le "${log_lines[$i]}" "${log_lines[$((i-1))]}"; then
      refuse "Release log is out of order" "${MODULE}.txt has ${log_lines[$((i-1))]} on line ${i} and ${log_lines[$i]} on line $((i+1)), which is not descending. Release post-processing reads the first line of this file, so a repair here is a separate decision from recording ${VERSION}. Fix the order by hand first."
    fi
  done
  dups=0
  for (( i=1; i<${#log_lines[@]}; i++ )); do
    [ "${log_lines[$i]}" = "${log_lines[$((i-1))]}" ] && dups=$((dups+1))
  done
  [ "$dups" -eq 0 ] || log_dups="${dups} adjacent duplicate line(s), left alone"

  found=0
  for line in ${log_lines[@]+"${log_lines[@]}"}; do
    [ "$line" = "$VERSION" ] && found=$((found+1))
  done
  if [ "$found" -gt 0 ]; then
    log_state="present"
    [ "$found" -eq 1 ] || log_state="present ${found} times"
  else
    log_state="absent"
    insert_at="${#log_lines[@]}"
    for i in "${!log_lines[@]}"; do
      if version_le "${log_lines[$i]}" "$VERSION"; then insert_at="$i"; break; fi
    done
    if [ "$insert_at" -eq 0 ]; then
      log_position="as the first line — release post-processing will run for ${VERSION}"
    elif [ "$insert_at" -eq "${#log_lines[@]}" ]; then
      log_position="at the end, after ${log_lines[$(( ${#log_lines[@]} - 1 ))]}"
    else
      log_position="between ${log_lines[$((insert_at-1))]} and ${log_lines[$insert_at]}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
tag_action="create it at ${COMMIT}"
[ "$tag_state" = "absent" ] || tag_action="leave it"
case "$release_state" in
  absent)    release_action="create it on ${TAG}" ;;
  draft)     release_action="publish the draft" ;;
  published) release_action="leave it" ;;
esac
case "$log_state" in
  "no file yet") log_action="create ${MODULE}.txt with ${VERSION}" ;;
  absent)        log_action="insert ${VERSION} ${log_position}" ;;
  *)             log_action="leave it" ;;
esac

printf '  %-14s %-28s %s\n' \
  "fact" "state now" "$([ "$APPLY" = true ] && echo "action" || echo "would do")" >&2
printf '  %-14s %-28s %s\n' "central" "all ${#coords[@]} coordinate(s) present" "nothing — read only" >&2
printf '  %-14s %-28s %s\n' "commit" "${commit_position}" "nothing — you attest it" >&2
printf '  %-14s %-28s %s\n' "tag" "${tag_state}" "${tag_action}" >&2
printf '  %-14s %-28s %s\n' "release" "${release_state}" "${release_action}" >&2
printf '  %-14s %-28s %s\n' "release log" "${log_state}" "${log_action}" >&2
[ -z "$log_dups" ] || note "  note: ${MODULE}.txt has ${log_dups}."
note ""

if [ "$APPLY" != true ]; then
  note "Plan only. Nothing was written. Re-run with --apply to write the actions above."
  exit 0
fi

# ---------------------------------------------------------------------------
# APPLY. The order is the dependency order, and the log is last on purpose: it is the only ledger
# with a consumer outside this repository, and the release path never shows that consumer a version
# whose tag and release are not already in place.
# ---------------------------------------------------------------------------
tag_outcome="already in place" release_outcome="already in place" log_outcome="already in place"
rc=0

if [ "$tag_state" = "absent" ] || [ "$release_state" != "published" ]; then
  # One script for both, the same one the release path uses, so the recovery and the release cannot
  # drift apart. It creates the ref, waits for it to become readable, adopts what exists, and
  # publishes a stranded draft. No RELEASE_ASSET: the Maven flow attaches a released pom.xml from
  # its build job's artifact, which a recovery deliberately does not restore.
  if GITHUB_REPOSITORY="$TARGET_REPO" GH_REPO="$TARGET_REPO" TAG="$TAG" BUILT_SHA="$COMMIT" \
       RELEASE_ASSET="" bash "$here/tag-and-release.sh" >&2; then
    [ "$tag_state" = "absent" ] && tag_outcome="written now"
    [ "$release_state" = "published" ] || release_outcome="written now"
  else
    tag_outcome="FAILED"; release_outcome="FAILED"; rc=1
  fi
fi

if [ "$rc" -eq 0 ]; then
  # Confirm the release is the shape registration needs before touching the log. tag-and-release.sh
  # already waited for the ref and compared the tag's target, so this asks the one thing it cannot:
  # that what exists now is a published release on this tag.
  if rel="$(gh release view "$TAG" --repo "$TARGET_REPO" --json isDraft,tagName 2>&1)" \
     && [ "$(jq -r '.isDraft' <<<"$rel")" = "false" ] \
     && [ "$(jq -r '.tagName' <<<"$rel")" = "$TAG" ]; then
    :
  else
    printf 'The release for %s is not a published release on that tag: %s\n' "$TAG" "$rel" >&2
    release_outcome="FAILED"; rc=1
  fi
fi

if [ "$rc" -ne 0 ]; then
  log_outcome="not attempted — the tag and release must be in place first"
elif [ "$log_state" = "present" ] || [[ "$log_state" == present* ]]; then
  :
else
  # Compare-and-swap: the blob sha read above is sent back, so a concurrent write loses rather than
  # being overwritten. On a conflict, re-read: if a real release landed the version meanwhile there
  # is nothing to do, and otherwise the position is recomputed against what is there now.
  put_log() { # <content-file> <sha-or-empty>
    local args=(-X PUT "repos/${RELEASE_LOG_REPO}/contents/${MODULE}.txt"
                -f "message=${MODULE}-${VERSION}"
                -f "branch=${RELEASE_LOG_REF}"
                -f "content=$(LC_ALL=C base64 < "$1" | LC_ALL=C tr -d '\n')")
    # The receiving workflow commits as github-actions[bot] with this same message shape. Internal
    # post-processing triggers on commits to this repository; matching both removes the only two
    # differences a trigger filter could distinguish (ADR 0009).
    args+=(-f "committer[name]=github-actions[bot]"
           -f "committer[email]=41898282+github-actions[bot]@users.noreply.github.com")
    [ -z "$2" ] || args+=(-f "sha=$2")
    gh api "${args[@]}"
  }

  build_content() { # writes the file with VERSION inserted at $insert_at
    local out="$1" i
    : > "$out"
    for i in "${!log_lines[@]}"; do
      [ "$i" -eq "$insert_at" ] && printf '%s\n' "$VERSION" >> "$out"
      printf '%s\n' "${log_lines[$i]}" >> "$out"
    done
    [ "$insert_at" -ge "${#log_lines[@]}" ] && printf '%s\n' "$VERSION" >> "$out"
    return 0
  }

  work="$WORK"
  attempt=0
  while :; do
    attempt=$((attempt+1))
    if [ "$log_state" = "no file yet" ]; then
      printf '%s\n' "$VERSION" > "$work/content"
      put_sha=""
    else
      build_content "$work/content"
      put_sha="$log_sha"
    fi

    if put_out="$(put_log "$work/content" "$put_sha" 2>&1)"; then
      # The PUT's own response is the confirmation, not a later GET: a read right after a write can
      # be served from cache, which is the race wait-for-tag-ref.sh exists for on the ref side.
      new_blob="$(jq -r '.content.sha // empty' <<<"$put_out" 2>/dev/null)"
      new_commit="$(jq -r '.commit.sha // empty' <<<"$put_out" 2>/dev/null)"
      if [ -n "$new_blob" ] && [ -n "$new_commit" ]; then
        log_outcome="written now (commit ${new_commit:0:7})"
        [ "${insert_at:-}" = 0 ] && note "${VERSION} is now the first line of ${MODULE}.txt: internal release post-processing should run for it. Check that it did."
      else
        printf '%s\n' "$put_out" >&2
        log_outcome="FAILED — the write was accepted but returned no commit"; rc=1
      fi
      break
    fi

    # 409 is the compare-and-swap conflict. A 422 covers that too, but also a malformed request, so
    # it only counts as a conflict when a re-read proves the file moved under us.
    if ! grep -qE 'HTTP 409|HTTP 422|"status": ?"4(09|22)"' <<<"$put_out"; then
      printf '%s\n' "$put_out" >&2
      log_outcome="FAILED — ${RELEASE_LOG_REPO} refused the write"; rc=1
      break
    fi
    if [ "$attempt" -ge 2 ]; then
      printf '%s\n' "$put_out" >&2
      log_outcome="FAILED — the file kept changing under the write"; rc=1
      break
    fi

    note "The release log changed under this write; re-reading before retrying."
    prev_sha="$log_sha"
    log_rc=0
    log_sha="$(log_read "$work/log")" || log_rc=$?
    if [ "$log_rc" -ne 0 ]; then
      log_outcome="FAILED — could not re-read after a conflict"; rc=1; break
    fi
    if [ "$log_sha" = "$prev_sha" ]; then
      printf '%s\n' "$put_out" >&2
      log_outcome="FAILED — the write was refused and the file had not changed, so this is not a conflict"; rc=1
      break
    fi
    log_lines=()
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue; log_lines+=("$line")
    done < "$work/log"
    for line in ${log_lines[@]+"${log_lines[@]}"}; do
      if [ "$line" = "$VERSION" ]; then
        log_outcome="written by someone else meanwhile"
        break 2
      fi
    done
    insert_at="${#log_lines[@]}"
    for i in "${!log_lines[@]}"; do
      if version_le "${log_lines[$i]}" "$VERSION"; then insert_at="$i"; break; fi
    done
    log_state="absent"
  done
fi

# ---------------------------------------------------------------------------
# What this run changed, per ledger. Non-zero while any of it is unfinished.
# ---------------------------------------------------------------------------
note ""
printf '  %-14s %s\n' "tag ${TAG}" "$tag_outcome" >&2
printf '  %-14s %s\n' "release" "$release_outcome" >&2
printf '  %-14s %s\n' "release log" "$log_outcome" >&2
note ""
if [ "$rc" -ne 0 ]; then
  note "Not finished. Nothing about the published artifacts changed, and re-running is safe: every"
  note "step here adopts what already exists. Do not treat this as done — an unnoticed hole in the"
  note "release log is what #189 records for octopus-sonar-automation 2.0.15."
else
  note "All three records are in place for ${MODULE} ${VERSION}."
  # Printed for every component, because nothing in the arguments says which flow released this
  # one, and the omission is unrecoverable once the release is immutable.
  note "If this component's releases carry a released pom.xml asset (the Maven flow attaches one), it is deliberately not restored here. Attach it by hand now, before the release becomes immutable."
fi
exit "$rc"
