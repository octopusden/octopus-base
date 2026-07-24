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
#   STAGING_PROFILE_ID              namespace, e.g. org.octopusden (required)
#   PUBLISH_LOG                     Gradle publish log, to read the compat repo key
#   RESUME_DEPLOYMENT_ID            optional: skip the search, use this deployment
#   REQUIRE_COORDS                  optional: "group:artifact ..." that must be present
#
# On failure it emits classification markers for the caller / TeamCity to scrape:
#   RELEASE_PUBLISH_CLASS=deterministic|transient|resumable
#   RELEASE_PUBLISH_RETRYABLE=false|true
#   RELEASE_PUBLISH_RESUME_DEPLOYMENT_ID=<id>   (when the run can be resumed)

set -uo pipefail

: "${MAVEN_USERNAME:?MAVEN_USERNAME is required}"
: "${MAVEN_PASSWORD:?MAVEN_PASSWORD is required}"
: "${BUILD_VERSION:?BUILD_VERSION is required}"
: "${STAGING_PROFILE_ID:?STAGING_PROFILE_ID is required}"
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
SEARCH_DEADLINE="${SEARCH_DEADLINE:-600}"
VALIDATE_DEADLINE="${VALIDATE_DEADLINE:-1800}"
PUBLISH_DEADLINE="${PUBLISH_DEADLINE:-1800}"
CENTRAL_DEADLINE="${CENTRAL_DEADLINE:-1800}"

DID="${RESUME_DEPLOYMENT_ID}"
REPO_KEY=""
STATUS_JSON="$TMP/portal-status.json"

classify() { # class retryable
  echo "RELEASE_PUBLISH_CLASS=$1"
  echo "RELEASE_PUBLISH_RETRYABLE=$2"
  : > "$TMP/publish-classified"
}

fail_deterministic() { classify deterministic false; echo "::error title=Deterministic publish failure::$*"; exit 1; }
fail_transient()     { classify transient true;      echo "::error title=Transient publish failure::$*"; exit 1; }
# After a deployment exists, a blind re-dispatch would upload the version twice.
fail_resumable() {
  classify resumable false
  [ -n "$DID" ] && echo "RELEASE_PUBLISH_RESUME_DEPLOYMENT_ID=$DID"
  [ -n "$REPO_KEY" ] && echo "RELEASE_PUBLISH_COMPAT_KEY=$REPO_KEY"
  echo "::error title=Resumable publish failure::$* Re-dispatch with resume-deployment-id=${DID:-<unknown>} instead of a plain re-run (a plain re-run would create a second deployment of ${BUILD_VERSION})."
  exit 1
}

# http METHOD URL OUTFILE -> prints HTTP status (000 on transport error)
http() {
  local method="$1" url="$2" out="$3" code
  code=$(curl "${NET[@]}" -o "$out" -w '%{http_code}' -X "$method" -H "$AUTH" -H 'Accept: application/json' "$url" 2>/dev/null)
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
  REPO_KEY=$(grep -oE "Created staging repository '[^']+'" "$PUBLISH_LOG" 2>/dev/null | head -1 | sed -E "s/^.*'([^']+)'.*$/\1/")
  [ -n "$REPO_KEY" ] \
    || fail_deterministic "No 'Created staging repository' line in the publish log — nothing was staged."
  echo "Compat staging repository: $REPO_KEY"

  # The search key is prefixed ("<user>/<ip>/<repo-id>"), so match by suffix.
  sf="$TMP/portal-search.json"
  deadline=$(( $(now) + SEARCH_DEADLINE ))
  while :; do
    code=$(http GET "$HOST/manual/search/repositories?ip=any&profile_id=${STAGING_PROFILE_ID}" "$sf")
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
      REPO_KEY="$REPO_KEY" fail_resumable "The staging repository was created but never appeared as a Portal deployment within ${SEARCH_DEADLINE}s."
    fi
    sleep 15
  done
fi
echo "Portal deployment id: $DID"
echo "RELEASE_PUBLISH_DEPLOYMENT_ID=$DID"
[ -n "$REPO_KEY" ] && echo "RELEASE_PUBLISH_COMPAT_KEY=$REPO_KEY"

# ---------------------------------------------------------------------------
# 2. Wait for VALIDATED (or notice it already moved on)
# ---------------------------------------------------------------------------
dump_errors() {
  jq -r 'if (.errors|type)=="object" then (.errors|to_entries[]|"  - \(.key): \(.value|tostring)")
         elif (.errors|type)=="array" then (.errors[]|"  - \(.|tostring)")
         else empty end' "$STATUS_JSON" 2>/dev/null \
    || { echo "  (raw status body):"; head -c 2000 "$STATUS_JSON"; echo; }
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
      echo "  status 404 — treating as propagation delay, still waiting..."
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
MAVEN_COORDS=()
for p in "${PURLS[@]:-}"; do
  [ -n "$p" ] || continue
  case "$p" in pkg:maven/*) : ;; *) continue ;; esac
  rest="${p#pkg:maven/}"
  ga="${rest%@*}"; ver="${rest##*@}"
  grp="${ga%/*}"; art="${ga##*/}"
  [ -n "$grp" ] && [ -n "$art" ] && [ -n "$ver" ] || continue
  MAVEN_COORDS+=("$grp:$art:$ver")
done

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
  case "$grp" in
    "$STAGING_PROFILE_ID"|"$STAGING_PROFILE_ID".*) : ;;
    *) fail_deterministic "Deployment $DID contains group '$grp' outside namespace '$STAGING_PROFILE_ID' — refusing to publish." ;;
  esac
done

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
if [ "$state" = "VALIDATED" ]; then
  resp="$TMP/portal-publish-resp"
  attempt=0
  while :; do
    attempt=$(( attempt + 1 ))
    code=$(http POST "$PORTAL/deployment/$DID" "$resp")
    echo "POST /deployment/$DID (attempt $attempt) -> HTTP $code"
    case "$code" in
      204|200) echo "Publish accepted."; break ;;
      401|403|400|404|409|422)
        echo "  (response body):"; head -c 2000 "$resp" 2>/dev/null; echo
        fail_deterministic "POST /deployment/$DID -> HTTP $code."
        ;;
      429)
        ra=$(awk 'tolower($0) ~ /^retry-after:/ {print $2}' "$resp" 2>/dev/null | tr -d '\r')
        sleep "${ra:-30}"
        ;;
      *)
        # Ambiguous: the publish may have been accepted. Never blindly re-POST —
        # settle, then decide from the deployment state.
        echo "  ambiguous response ($code); settling before re-checking status..."
        sleep 45
        http POST "$PORTAL/status?id=$DID" "$STATUS_JSON" >/dev/null
        state=$(poll_state)
        echo "  post-settle state=${state:-unknown}"
        case "$state" in
          PUBLISHING|PUBLISHED) break ;;
          VALIDATED)            : ;;  # genuinely not accepted -> retry the POST
          FAILED) echo "::group::Errors"; dump_errors; echo "::endgroup::"
                  fail_deterministic "Deployment $DID became FAILED during publish." ;;
          *) fail_resumable "Deployment $DID is in state '${state:-unknown}' after an ambiguous publish call." ;;
        esac
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
