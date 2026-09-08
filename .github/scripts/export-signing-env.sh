#!/usr/bin/env bash
# Source this before a ./gradlew invocation that may need to sign.
#
# GitHub creates an `env:` entry for an unset secret with an EMPTY value, so exporting
# ORG_GRADLE_PROJECT_signingKey straight from `secrets.GPG_PRIVATE_KEY` defines the variable
# whether or not the secret exists. Consumers decide `signing.isRequired` with
# System.getenv().containsKey(...) — over a dozen of them — so an absent secret made signing
# REQUIRED with nothing to sign with, and the build died on "no configured signatory". Exporting
# only when both values are non-blank keeps `containsKey` false in exactly that case.
#
# Reads SIGNING_KEY and SIGNING_PASSPHRASE. Covered by
# .github/scripts/test/signing-env-scenarios.sh.

if [ -n "${SIGNING_KEY:-}" ] && [ -n "${SIGNING_PASSPHRASE:-}" ]; then
  export ORG_GRADLE_PROJECT_signingKey="$SIGNING_KEY"
  export ORG_GRADLE_PROJECT_signingPassword="$SIGNING_PASSPHRASE"
  echo "Signing credentials present; artifacts will be signed."
elif [ -n "${SIGNING_KEY:-}" ] || [ -n "${SIGNING_PASSPHRASE:-}" ]; then
  # Half a credential is never what anyone meant, and it fails deep inside Gradle with a message
  # that names neither secret. Refuse here instead.
  have=SIGNING_KEY; missing=SIGNING_PASSPHRASE
  [ -n "${SIGNING_KEY:-}" ] || { have=SIGNING_PASSPHRASE; missing=SIGNING_KEY; }
  echo "::error title=Incomplete signing credentials::${have} is set but ${missing} is empty. Set both secrets (GPG_PRIVATE_KEY and GPG_PASSPHRASE) or neither." >&2
  exit 1
else
  # Neither set: leave ORG_GRADLE_PROJECT_* undefined so a consumer's containsKey check reports
  # "not required" rather than "required, no signatory".
  echo "No signing credentials; publishing unsigned."
fi
