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

# The status is passed EXPLICITLY. Reading $? inside check is a trap: a command substitution
# anywhere in the argument list runs first and resets it, so an assertion whose failure message
# interpolates a log would report PASS whatever happened. `$?` expands left to right, so it is
# still the status of the command before the semicolon when it is the first argument.
check() { # check <status> <name> <why-it-matters>
  if [ "$1" -eq 0 ]; then echo "PASS  $2"; pass=$((pass+1))
  else echo "FAIL  $2"; echo "      $3"; fail=$((fail+1)); fi
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
probe_rc "KEYDATA" "PASSDATA"; check $? "succeeds when both are set" "it refused a complete credential"
[ "$(probe_exports "KEYDATA" "PASSDATA")" = "set|set" ]; check $? \
  "exports both ORG_GRADLE_PROJECT_ variables" \
  "a signed publication needs them, so the signed path breaks without this"

echo "-- neither present: the case this exists for ----------------------------"
probe_rc "" ""; check $? "succeeds when neither is set" \
  "a routed publish with no GPG secrets must still run"
[ "$(probe_exports "" "")" = "|" ]; check $? \
  "exports NEITHER variable" \
  "defining them empty is the whole bug: consumers use containsKey, so signing became required with no signatory"

echo "-- half a credential ----------------------------------------------------"
! probe_rc "KEYDATA" ""; check $? "refuses when only the key is set" \
  "it continued, so the build would die inside Gradle on a message naming neither secret"
grep -q 'SIGNING_PASSPHRASE' "$tmp/out"; check $? "names the missing half (passphrase)" \
  "the error must say which secret to set: $(cat "$tmp/out")"
! probe_rc "" "PASSDATA"; check $? "refuses when only the passphrase is set" "it continued"
grep -q 'SIGNING_KEY' "$tmp/out"; check $? "names the missing half (key)" \
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
    // Groovy DSL: the property is `required`. Kotlin consumers spell the same thing isRequired.
    required = System.getenv().containsKey('ORG_GRADLE_PROJECT_signingKey')
    def signingKey = findProperty('signingKey')
    def signingPassword = findProperty('signingPassword')
    useInMemoryPgpKeys(signingKey, signingPassword)
    sign(publishing.publications['maven'])
}
G

# Exactly what the workflow does, with the secrets absent.
( export SIGNING_KEY="" SIGNING_PASSPHRASE="" \
  && . "$SCRIPT" >/dev/null \
  && cd "$root/gradle-quality-plugin" \
  && ./gradlew --project-dir "$proj" publishMavenPublicationToLocalRepository \
       -q -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false
) > "$tmp/log" 2>&1
rc=$?
check "$rc" "publishes with no signing secrets at all" \
  "exit $rc — $(grep -m1 -iE 'signatory|What went wrong' -A1 "$tmp/log" | tail -1 || echo 'see log')"
! grep -qi 'no configured signatory' "$tmp/log"; check $? \
  "does not fail on 'no configured signatory'" \
  "the empty-value export is back: containsKey saw the variable and required signing"

# And the naive version really would have failed, so the assertion above is not vacuous.
( export ORG_GRADLE_PROJECT_signingKey="" ORG_GRADLE_PROJECT_signingPassword="" \
  && cd "$root/gradle-quality-plugin" \
  && ./gradlew --project-dir "$proj" publishMavenPublicationToLocalRepository \
       -q -Dorg.gradle.configureondemand=false -Dorg.gradle.configuration-cache=false
) > "$tmp/log-naive" 2>&1
[ "$?" -ne 0 ]; check $? "the naive export fails, proving the case is real" \
  "exporting the variables empty did NOT fail, so this suite proves nothing about the fix"

echo "-- in the consumer checkout layout --------------------------------------"
# The reusable workflow runs inside the CONSUMER's checkout, where octopus-base's scripts do not
# exist — only the pinned sparse checkout at .octopus-base-helper does. Sourcing the script by a
# bare .github/scripts/ path therefore died with "No such file or directory" before Gradle ran,
# and every assertion above missed it by executing the script from this repository.
WORKFLOW="$root/.github/workflows/common-java-gradle-release.yml"

# A consumer tree: its own files, no .github/scripts, plus the helper checkout as
# actions/checkout(path: .octopus-base-helper) would leave it.
consumer="$tmp/consumer-checkout"
mkdir -p "$consumer/.github/workflows" "$consumer/.octopus-base-helper/.github/scripts"
: > "$consumer/build.gradle.kts"
: > "$consumer/.github/workflows/release.yml"
cp "$SCRIPT" "$consumer/.octopus-base-helper/.github/scripts/export-signing-env.sh"

# Run each publish step's actual source line, taken from the workflow, in that tree.
for step in 'Publish to Sonatype Nexus' 'Publish to GitHub Packages'; do
  line=$(awk -v s="      - name: $step" '
    $0 == s { inside = 1; next }
    inside && /^      - name:/ { exit }
    inside && /export-signing-env\.sh/ { print; exit }' "$WORKFLOW" | sed 's/^ *//')
  [ -n "$line" ]; check $? "'$step' sources the signing helper" \
    "the step no longer sources it at all, so the secrets never reach Gradle"

  ( cd "$consumer" && export SIGNING_KEY="" SIGNING_PASSPHRASE="" && eval "$line" ) \
    > "$tmp/consumer-out" 2>&1
  check $? "'$step' resolves that path in a consumer checkout" \
    "$(head -1 "$tmp/consumer-out") — the path is relative to the consumer tree, not to octopus-base"
done

# Non-vacuity: the bare path this replaced really does fail in that same tree.
( cd "$consumer" && . .github/scripts/export-signing-env.sh ) > "$tmp/bare-out" 2>&1
[ "$?" -ne 0 ]; check $? "a bare .github/scripts path fails there, as it did in production" \
  "the fake consumer tree is wrong — it has the script where a real consumer would not, so the checks above prove nothing"

echo "-- the helper checkout actually happens for those releases ---------------"
# Correcting the path is not enough: both helper steps required publish-to-nexus, so a
# GitHub-Packages-only release reached the publish step with no .octopus-base-helper at all.
for step in 'Resolve octopus-base helper ref' 'Fetch octopus-base helpers'; do
  cond=$(awk -v s="      - name: $step" '
    $0 == s { inside = 1; next }
    inside && /^      - name:/ { exit }
    inside && /^        if:/ { print; exit }' "$WORKFLOW")
  grep -q 'github-packages-publications' <<<"$cond"; check $? \
    "'$step' also fires for a GitHub-Packages-only release" \
    "its condition is${cond:-  (none)} — with publish-to-nexus false the helper is never fetched and the publish step finds no script"
done

# And the sparse checkout has to include the directory the script lives in.
sparse=$(grep -A1 'path: .octopus-base-helper' "$WORKFLOW" | grep 'sparse-checkout:' | sed 's/.*sparse-checkout: *//')
case "$(realpath --relative-to=. "$SCRIPT" 2>/dev/null || echo ".github/scripts/export-signing-env.sh")" in
  "$sparse"/*) true ;;
  *) case ".github/scripts/export-signing-env.sh" in "$sparse"/*) true ;; *) false ;; esac ;;
esac
check $? "the sparse checkout includes the script's directory" \
  "sparse-checkout is '$sparse', which would not fetch the signing helper"

echo
echo "passed=$pass failed=$fail"
rm -rf "$tmp"
[ "$fail" -eq 0 ]
