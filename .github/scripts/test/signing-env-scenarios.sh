#!/usr/bin/env bash
# Exercises .github/scripts/export-signing-env.sh, and then the case it exists for against a real
# Gradle build: a consumer that decides signing.isRequired with containsKey, publishing with no
# signing secrets at all. That combination used to fail on "no configured signatory", because an
# unset GitHub secret still creates the env entry — with an empty value.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
SCRIPT="$root/.github/scripts/export-signing-env.sh"
tmp="$(mktemp -d)"
pass=0; fail=0

check() { # check <name> <why-it-matters>
  if [ "$?" -eq 0 ]; then echo "PASS  $1"; pass=$((pass+1))
  else echo "FAIL  $1"; echo "      $2"; fail=$((fail+1)); fi
}

# The script is SOURCED by the workflow, and refuses a half credential with `exit 1` — which
# aborts the step. That matters: the Sonatype step runs without `set -e`, so a `return 1` there
# would be ignored and gradlew would run anyway. Two helpers, because a sourced `exit` cannot be
# observed from the same shell that is checking the exports.

# What it exported. Sourced in THIS shell, so the exports are visible; only valid for cases the
# script does not refuse.
probe_exports() { # probe_exports [KEY] [PASSPHRASE] -> "<key>|<pass>"
  (
    export SIGNING_KEY="${1-}" SIGNING_PASSPHRASE="${2-}"
    unset ORG_GRADLE_PROJECT_signingKey ORG_GRADLE_PROJECT_signingPassword
    . "$SCRIPT" >/dev/null 2>&1
    printf '%s|%s' "${ORG_GRADLE_PROJECT_signingKey+set}" "${ORG_GRADLE_PROJECT_signingPassword+set}"
  )
}

# Whether it refused, and what it said. The subshell absorbs the sourced `exit`.
probe_rc() { # probe_rc [KEY] [PASSPHRASE] -> writes output to $tmp/out, returns the exit code
  (
    export SIGNING_KEY="${1-}" SIGNING_PASSPHRASE="${2-}"
    . "$SCRIPT"
  ) > "$tmp/out" 2>&1
}

echo "-- both present ---------------------------------------------------------"
probe_rc "KEYDATA" "PASSDATA"; check "succeeds when both are set" "it refused a complete credential"
[ "$(probe_exports "KEYDATA" "PASSDATA")" = "set|set" ]; check \
  "exports both ORG_GRADLE_PROJECT_ variables" \
  "a signed publication needs them, so the signed path breaks without this"

echo "-- neither present: the case this exists for ----------------------------"
probe_rc "" ""; check "succeeds when neither is set" \
  "a routed publish with no GPG secrets must still run"
[ "$(probe_exports "" "")" = "|" ]; check \
  "exports NEITHER variable" \
  "defining them empty is the whole bug: consumers use containsKey, so signing became required with no signatory"

echo "-- half a credential ----------------------------------------------------"
! probe_rc "KEYDATA" ""; check "refuses when only the key is set" \
  "it continued, so the build would die inside Gradle on a message naming neither secret"
grep -q 'SIGNING_PASSPHRASE' "$tmp/out"; check "names the missing half (passphrase)" \
  "the error must say which secret to set: $(cat "$tmp/out")"
! probe_rc "" "PASSDATA"; check "refuses when only the passphrase is set" "it continued"
grep -q 'SIGNING_KEY' "$tmp/out"; check "names the missing half (key)" \
  "the error must say which secret to set: $(cat "$tmp/out")"

echo "-- against a real build -------------------------------------------------"
# A consumer in the shape over a dozen of ours are in: signing required iff the env var EXISTS.
proj="$tmp/consumer"; mkdir -p "$proj"
cat > "$proj/settings.gradle" <<'G'
rootProject.name = 'consumer'
G
cat > "$proj/build.gradle" <<'G'
plugins { id 'java'; id 'maven-publish'; id 'signing' }
group = 'org.octopusden.test'
version = '1.0.0'
publishing {
    publications { maven(MavenPublication) { from components.java } }
    repositories { maven { name = 'Local'; url = uri("${rootDir}/out") } }
}
signing {
    isRequired = System.getenv().containsKey('ORG_GRADLE_PROJECT_signingKey')
    def signingKey = findProperty('signingKey')
    def signingPassword = findProperty('signingPassword')
    useInMemoryPgpKeys(signingKey, signingPassword)
    sign(publishing.publications['maven'])
}
G

# Exactly what the workflow does, with the secrets absent.
( cd "$proj" && export SIGNING_KEY="" SIGNING_PASSPHRASE="" \
  && . "$SCRIPT" >/dev/null \
  && "$root/gradlew" --project-dir "$proj" -p "$proj" publishMavenPublicationToLocalRepository \
       --offline -q -Dorg.gradle.configuration-cache=false
) > "$tmp/log" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check "publishes with no signing secrets at all" \
  "exit $rc — this is the regression: $(grep -m1 -i 'signatory\|FAILURE' "$tmp/log" || echo 'see log')"
! grep -qi 'no configured signatory' "$tmp/log"; check \
  "does not fail on 'no configured signatory'" \
  "the empty-value export is back: containsKey saw the variable and required signing"

# And the naive version really would have failed, so the assertion above is not vacuous.
( cd "$proj" && export ORG_GRADLE_PROJECT_signingKey="" ORG_GRADLE_PROJECT_signingPassword="" \
  && "$root/gradlew" --project-dir "$proj" -p "$proj" publishMavenPublicationToLocalRepository \
       --offline -q -Dorg.gradle.configuration-cache=false
) > "$tmp/log-naive" 2>&1
[ "$?" -ne 0 ]; check "the naive export fails, proving the case is real" \
  "exporting the variables empty did NOT fail, so this suite proves nothing about the fix"

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
