#!/usr/bin/env bash
#
# Finish a Sonatype release through the Central Portal Publisher API.
#
# The OSSRH-compat Nexus2 `release` transition is unreliable (it leaves the
# deployment `closed`, so nothing reaches Maven Central). This script replaces it:
# after Gradle has uploaded + closed the staging repository, it maps that repo to
# its Portal deployment, waits for VALIDATED, publishes explicitly, waits for
# PUBLISHED, and finally verifies the artifacts are resolvable on Maven Central.
#
# Inputs (env):
#   MAVEN_USERNAME, MAVEN_PASSWORD  Portal/OSSRH token pair (required)
#   BUILD_VERSION                   expected release version (required)
#   STAGING_PROFILE_ID              namespace, e.g. org.octopusden (optional; when
#                                   blank the search is unfiltered and the namespace
#                                   check is skipped — matches "blank = auto-lookup")
#   PUBLISH_LOG                     Gradle publish log, to read the compat repo key
#   RESUME_DEPLOYMENT_ID            optional: skip the search, use this deployment
#   REQUIRE_COORDS                  optional: "group:artifact ..." that must be present
#
# Emits classification markers for the caller / TeamCity to scrape:
#   RELEASE_PUBLISH_CLASS=published                  (success)
#   RELEASE_PUBLISH_CLASS=deterministic|transient|resumable
#   RELEASE_PUBLISH_RETRYABLE=false|true
#   RELEASE_PUBLISH_RESUME_DEPLOYMENT_ID=<id>        (resumable, deployment known)
#   RELEASE_PUBLISH_COMPAT_KEY=<key>                 (staging repo, for manual triage)

set -uo pipefail

: "${MAVEN_USERNAME:?MAVEN_USERNAME is required}"
: "${MAVEN_PASSWORD:?MAVEN_PASSWORD is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
STAGING_PROFILE_ID="${STAGING_PROFILE_ID:-}"
PUBLISH_LOG="${PUBLISH_LOG:-}"
RESUME_DEPLOYMENT_ID="${RESUME_DEPLOYMENT_ID:-}"
REQUIRE_COORDS="${REQUIRE_COORDS:-}"
TMP="${RUNNER_TEMP:-/tmp}"

HOST="https://ossrh-staging-api.central.sonatype.com"
PORTAL="https://central.sonatype.com/api/v1/publisher"
REPO1="https://repo1.maven.org/maven2"
# Bearer must be base64 of "user:token" with no trailing newline and no line wrap.
AUTH="Authorization: Bearer $(printf '%s' "${MAVEN_USERNAME}:${MAVEN_PASSWORD}" | base64 | tr -d '\n')"
NET=(-sS --connect-timeout 15 --max-time 120)

# Deadlines (seconds) — overridable for the canary.
#
# PUBLISH_DEADLINE is set from an observation rather than guessed. In
# octopus-components-registry-service 3.0.9 (deployment b8df3ec1, run 30552430027,
# 2026-07-30) the publish was accepted at 14:38:33 and this script gave up at 15:08:35 —
# exactly the 1800s then in force, with the deployment still PUBLISHING. Central did
# finish shortly afterwards, at about 15:10, so roughly 32 minutes in total; that last
# figure comes from the release notes written by hand afterwards, NOT from the run, which
# had already stopped and so recorded no PUBLISHED state. 2700s covers the ~32 minutes
# with about 13 minutes to spare. Note it is one data point: no second slow publish has
# been observed.
#
# The publish had succeeded; only the waiting gave up. Because that happens after the
# upload, the tag, the GitHub release and the release-log entry were all skipped, leaving
# a state the pipeline cannot finish by itself (see octopus-base#189).
#
# Before raising this further, check the OUTER budget, which this script cannot see.
# TeamCity's poller waits on the whole release run; its OCTOPUS_RELEASE_TIMEOUT is
# configured in TeamCity, not declared here, and was 60 minutes when this was written.
# 2700s does NOT by itself guarantee the run fits: the deadlines below are sequential, so
# this wait plus CENTRAL_DEADLINE alone permit 75 minutes, and all four permit 115 —
# before any build, tagging or registration time. In practice the phases after PUBLISHED
# cost seconds (measured: 6s in octopus-dms-service run 30597896298), which is why the
# arithmetic has not bitten. Treat 2700 as "covers the observed publish", not as
# "provably inside the TeamCity budget".
SEARCH_DEADLINE="${SEARCH_DEADLINE:-600}"
VALIDATE_DEADLINE="${VALIDATE_DEADLINE:-1800}"
PUBLISH_DEADLINE="${PUBLISH_DEADLINE:-2700}"
CENTRAL_DEADLINE="${CENTRAL_DEADLINE:-1800}"
# Settling window before re-reading state after an inconclusive publish response.
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"

DID="${RESUME_DEPLOYMENT_ID}"
REPO_KEY=""
STATUS_JSON="$TMP/portal-status.json"

classify() { # class retryable
  echo "RELEASE_PUBLISH_CLASS=$1"
  echo "RELEASE_PUBLISH_RETRYABLE=$2"
  [ -n "$DID" ] && echo "RELEASE_PUBLISH_DEPLOYMENT_ID=$DID"
  [ -n "$REPO_KEY" ] && echo "RELEASE_PUBLISH_COMPAT_KEY=$REPO_KEY"
  : > "$TMP/publish-classified"
}

fail_deterministic() { classify deterministic false; echo "::error title=Deterministic publish failure::$*"; exit 1; }
fail_transient()     { classify transient true;      echo "::error title=Transient publish failure::$*"; exit 1; }
# After a deployment exists, a blind re-dispatch would upload the version twice.
fail_resumable() {
  classify resumable false
  if [ -n "$DID" ]; then
    echo "RELEASE_PUBLISH_RESUME_DEPLOYMENT_ID=$DID"
    echo "::error title=Resumable publish failure::$* Re-dispatch with resume-deployment-id=${DID} — a plain re-run would upload ${BUILD_VERSION} a second time."
  else
    echo "::error title=Resumable publish failure::$* The artifacts are staged but no Portal deployment id is known yet. Do NOT plainly re-run (that uploads ${BUILD_VERSION} again): look it up with the compat key above via GET ${HOST}/manual/search/repositories?ip=any (Bearer auth) and re-dispatch with resume-deployment-id, or drop that staging repository first."
  fi
  exit 1
}

# http METHOD URL OUTFILE -> prints HTTP status (000 on transport error).
# Response headers land in <OUTFILE>.headers (needed for Retry-After).
http() {
  local method="$1" url="$2" out="$3" code
  code=$(curl "${NET[@]}" -o "$out" -D "${out}.headers" -w '%{http_code}' -X "$method" -H "$AUTH" -H 'Accept: application/json' "$url" 2>/dev/null)
  if [ -z "$code" ]; then echo "000"; else echo "$code"; fi
}

now() { date +%s; }

# ---------------------------------------------------------------------------
# 1. Locate the Portal deployment
# ---------------------------------------------------------------------------
if [ -n "$DID" ]; then
  echo "Resuming deployment $DID (upload skipped)."
else
  [ -n "$PUBLISH_LOG" ] && [ -f "$PUBLISH_LOG" ] \
    || fail_deterministic "PUBLISH_LOG is required when RESUME_DEPLOYMENT_ID is not set."
  mapfile -t created < <(grep -oE "Created staging repository '[^']+'" "$PUBLISH_LOG" 2>/dev/null | sed -E "s/^.*'([^']+)'.*$/\1/" | sort -u)
  if [ "${#created[@]}" -eq 0 ]; then
    fail_deterministic "No 'Created staging repository' line in the publish log — nothing was staged."
  elif [ "${#created[@]}" -gt 1 ]; then
    printf 'Staged repositories: %s\n' "${created[*]}"
    fail_deterministic "The build created ${#created[@]} staging repositories; this flow publishes exactly one. Publish them manually or split the release."
  fi
  REPO_KEY="${created[0]}"
  echo "Compat staging repository: $REPO_KEY"
  echo "RELEASE_PUBLISH_COMPAT_KEY=$REPO_KEY"

  # The search key is prefixed ("<user>/<ip>/<repo-id>"), so match by suffix.
  # Without a namespace the search is unfiltered — the key-suffix match still pins it.
  search_url="$HOST/manual/search/repositories?ip=any"
  [ -n "$STAGING_PROFILE_ID" ] && search_url="${search_url}&profile_id=${STAGING_PROFILE_ID}"
  sf="$TMP/portal-search.json"
  deadline=$(( $(now) + SEARCH_DEADLINE ))
  while :; do
    code=$(http GET "$search_url" "$sf")
    if [ "$code" = "200" ]; then
      DID=$(jq -r --arg k "$REPO_KEY" '.repositories[]? | select(.key | endswith($k)) | .portal_deployment_id // empty' "$sf" 2>/dev/null | head -1)
      [ -n "$DID" ] && [ "$DID" != "null" ] && break
      echo "Portal deployment id not published yet for $REPO_KEY; waiting..."
    elif [ "$code" = "401" ] || [ "$code" = "403" ]; then
      fail_deterministic "GET /manual/search/repositories -> HTTP $code (credentials/permissions)."
    else
      echo "GET /manual/search/repositories -> HTTP $code; retrying..."
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      echo "  (last search body):"; head -c 2000 "$sf" 2>/dev/null; echo
      fail_resumable "The staging repository was created but never appeared as a Portal deployment within ${SEARCH_DEADLINE}s."
    fi
    sleep 15
  done
fi
echo "Portal deployment id: $DID"
echo "RELEASE_PUBLISH_DEPLOYMENT_ID=$DID"

# ---------------------------------------------------------------------------
# 2. Wait for VALIDATED (or notice it already moved on)
# ---------------------------------------------------------------------------
dump_errors() {
  local out
  out=$(jq -r 'if (.errors|type)=="object" then (.errors|to_entries[]|"  - \(.key): \(.value|tostring)")
               elif (.errors|type)=="array" then (.errors[]|"  - \(.|tostring)")
               else empty end' "$STATUS_JSON" 2>/dev/null)
  if [ -n "$out" ]; then echo "$out"; else echo "  (no .errors field; raw status body):"; head -c 2000 "$STATUS_JSON"; echo; fi
}

poll_state() { jq -r '.deploymentState // empty' "$STATUS_JSON" 2>/dev/null; }

state=""
deadline=$(( $(now) + VALIDATE_DEADLINE ))
while :; do
  code=$(http POST "$PORTAL/status?id=$DID" "$STATUS_JSON")
  state=$(poll_state)
  echo "POST /status?id=$DID -> HTTP $code state=${state:-?}"
  case "$code" in
    200) : ;;
    401|403) fail_deterministic "POST /status -> HTTP $code (credentials/permissions)." ;;
    404)
      # Right after the hand-off the deployment may not be queryable yet.
      echo "  status 404 — treating as propagation delay, still waiting (verify the id if this persists)..."
      ;;
    *) echo "  transient HTTP $code, retrying..." ;;
  esac
  case "$state" in
    VALIDATED)            break ;;
    PUBLISHING|PUBLISHED) echo "Deployment already $state — skipping the publish call."; break ;;
    FAILED)
      echo "::group::Deployment validation errors"; dump_errors; echo "::endgroup::"
      fail_deterministic "Deployment $DID is FAILED (validation). Fix the cause; a FAILED deployment cannot be published or resumed."
      ;;
    *) : ;;  # PENDING / VALIDATING / empty
  esac
  if [ "$(now)" -ge "$deadline" ]; then
    fail_resumable "Deployment $DID did not reach VALIDATED within ${VALIDATE_DEADLINE}s (last state=${state:-unknown})."
  fi
  sleep 15
done

# ---------------------------------------------------------------------------
# 3. Guard: the deployment must be the one we just built
#    (protects against a wrong resume-deployment-id publishing someone else's work)
# ---------------------------------------------------------------------------
mapfile -t PURLS < <(jq -r '.purls[]? // empty' "$STATUS_JSON" 2>/dev/null | sed 's/?.*$//')
declare -a MAVEN_COORDS=()
for p in "${PURLS[@]:-}"; do
  [ -n "$p" ] || continue
  case "$p" in pkg:maven/*) : ;; *) continue ;; esac
  rest="${p#pkg:maven/}"
  ga="${rest%@*}"; ver="${rest##*@}"
  grp="${ga%/*}"; art="${ga##*/}"
  [ -n "$grp" ] && [ -n "$art" ] && [ -n "$ver" ] || continue
  MAVEN_COORDS+=("$grp:$art:$ver")
done

# Classifier-stripped purls (sources/javadoc) collapse into duplicates.
if [ "${#MAVEN_COORDS[@]}" -gt 0 ]; then
  mapfile -t MAVEN_COORDS < <(printf '%s\n' "${MAVEN_COORDS[@]}" | sort -u)
fi

if [ "${#MAVEN_COORDS[@]}" -eq 0 ]; then
  echo "  (raw status body):"; head -c 2000 "$STATUS_JSON"; echo
  fail_deterministic "No Maven coordinates (purls) reported for deployment $DID — cannot verify what would be published."
fi

echo "::group::Deployment coordinates"
printf '  %s\n' "${MAVEN_COORDS[@]}"
echo "::endgroup::"

for c in "${MAVEN_COORDS[@]}"; do
  grp="${c%%:*}"; ver="${c##*:}"
  [ "$ver" = "$BUILD_VERSION" ] \
    || fail_deterministic "Deployment $DID contains version '$ver' but this release is '$BUILD_VERSION' — refusing to publish (wrong resume-deployment-id?)."
  if [ -n "$STAGING_PROFILE_ID" ]; then
    case "$grp" in
      "$STAGING_PROFILE_ID"|"$STAGING_PROFILE_ID".*) : ;;
      *) fail_deterministic "Deployment $DID contains group '$grp' outside namespace '$STAGING_PROFILE_ID' — refusing to publish." ;;
    esac
  fi
done
[ -n "$STAGING_PROFILE_ID" ] || echo "::warning::No staging-profile-id configured — namespace check skipped (the version was still verified)."


for want in $REQUIRE_COORDS; do
  found=false
  for c in "${MAVEN_COORDS[@]}"; do
    [ "${c%:*}" = "$want" ] && found=true && break
  done
  $found || fail_deterministic "Deployment $DID does not contain the required coordinate '$want:$BUILD_VERSION'."
done

# ---------------------------------------------------------------------------
# 4. Publish (irreversible)
# ---------------------------------------------------------------------------
# Any inconclusive response is reconciled against the deployment state rather than
# re-POSTed or declared fatal: the publish may have been accepted, and a late
# 400/409 usually means "no longer VALIDATED", i.e. it already went through.
reconcile_after_publish() { # $1 = context for the log
  echo "  $1 — settling, then re-reading the deployment state..."
  sleep "$SETTLE_SECONDS"
  http POST "$PORTAL/status?id=$DID" "$STATUS_JSON" >/dev/null
  state=$(poll_state)
  echo "  post-settle state=${state:-unknown}"
  case "$state" in
    PUBLISHING|PUBLISHED) return 0 ;;
    VALIDATED)            return 1 ;;
    FAILED)
      echo "::group::Deployment errors"; dump_errors; echo "::endgroup::"
      fail_deterministic "Deployment $DID became FAILED during publish."
      ;;
    *) fail_resumable "Deployment $DID is in state '${state:-unknown}' after an inconclusive publish call." ;;
  esac
}

if [ "$state" = "VALIDATED" ]; then
  resp="$TMP/portal-publish-resp"
  attempt=0
  while :; do
    attempt=$(( attempt + 1 ))
    code=$(http POST "$PORTAL/deployment/$DID" "$resp")
    echo "POST /deployment/$DID (attempt $attempt) -> HTTP $code"
    case "$code" in
      204|200) echo "Publish accepted."; break ;;
      401|403)
        echo "  (response body):"; head -c 2000 "$resp" 2>/dev/null; echo
        fail_deterministic "POST /deployment/$DID -> HTTP $code (credentials/permissions)."
        ;;
      400|404|409|422)
        # May equally mean "already past VALIDATED" — check before condemning it.
        echo "  (response body):"; head -c 2000 "$resp" 2>/dev/null; echo
        if reconcile_after_publish "HTTP $code"; then break; fi
        fail_deterministic "POST /deployment/$DID -> HTTP $code and the deployment is still VALIDATED."
        ;;
      429)
        ra=$(awk 'BEGIN{IGNORECASE=1} /^retry-after:/ {gsub(/\r/,""); print $2}' "${resp}.headers" 2>/dev/null | head -1)
        echo "  rate limited; sleeping ${ra:-30}s"
        sleep "${ra:-30}"
        ;;
      *)
        if reconcile_after_publish "inconclusive response ($code)"; then break; fi
        ;;
    esac
    [ "$attempt" -ge 5 ] && fail_resumable "Publish call for $DID did not succeed after $attempt attempts."
  done
fi

# ---------------------------------------------------------------------------
# 5. Wait for PUBLISHED
# ---------------------------------------------------------------------------
deadline=$(( $(now) + PUBLISH_DEADLINE ))
while :; do
  code=$(http POST "$PORTAL/status?id=$DID" "$STATUS_JSON")
  state=$(poll_state)
  echo "POST /status?id=$DID -> HTTP $code state=${state:-?}"
  case "$code" in
    401|403) fail_deterministic "POST /status -> HTTP $code while waiting for PUBLISHED (credentials/permissions)." ;;
    *) : ;;
  esac
  case "$state" in
    PUBLISHED) echo "Deployment $DID is PUBLISHED."; break ;;
    FAILED)
      echo "::group::Deployment errors"; dump_errors; echo "::endgroup::"
      fail_deterministic "Deployment $DID became FAILED while publishing."
      ;;
    *) : ;;
  esac
  if [ "$(now)" -ge "$deadline" ]; then
    fail_resumable "Deployment $DID did not reach PUBLISHED within ${PUBLISH_DEADLINE}s (last state=${state:-unknown})."
  fi
  sleep 20
done

# ---------------------------------------------------------------------------
# 6. Verify the artifacts are actually resolvable on Maven Central
#    (a green publish alone is not "done" — consumers resolve from repo1)
# ---------------------------------------------------------------------------
echo "::group::Verifying artifacts on Maven Central"
deadline=$(( $(now) + CENTRAL_DEADLINE ))
pending=("${MAVEN_COORDS[@]}")
while [ "${#pending[@]}" -gt 0 ]; do
  still=()
  for c in "${pending[@]}"; do
    grp="${c%%:*}"; rest="${c#*:}"; art="${rest%%:*}"; ver="${rest##*:}"
    url="$REPO1/${grp//./\/}/$art/$ver/$art-$ver.pom"
    code=$(curl "${NET[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    if [ "$code" = "200" ]; then
      echo "  OK   $c"
    else
      echo "  wait $c (HTTP ${code:-?})"
      still+=("$c")
    fi
  done
  pending=("${still[@]:-}")
  # `still` may contain a single empty element after expansion of an empty array.
  [ "${#pending[@]}" -eq 1 ] && [ -z "${pending[0]}" ] && pending=()
  [ "${#pending[@]}" -eq 0 ] && break
  if [ "$(now)" -ge "$deadline" ]; then
    echo "::endgroup::"
    fail_resumable "Published, but ${#pending[@]} artifact(s) were not resolvable on Maven Central within ${CENTRAL_DEADLINE}s: ${pending[*]}."
  fi
  sleep 30
done
echo "::endgroup::"

echo "RELEASE_PUBLISH_CLASS=published"
echo "RELEASE_PUBLISH_RETRYABLE=false"
echo "All ${#MAVEN_COORDS[@]} artifact(s) of $BUILD_VERSION are published and resolvable on Maven Central."
