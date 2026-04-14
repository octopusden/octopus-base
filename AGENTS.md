# Local Workflow Contract Rules

- When changing the reusable workflow merge contract (workflow names, required checks, merge-gate semantics, or verifier expectations), update the canary or consumer tests in the same change set.
- For `octopus-base`, keep `octopus-test` verification aligned with the current contract instead of validating an outdated workflow set.

## PR Pipeline (Merge Gate)

```
PR opened / pushed
  │
  ├─ plugin-quality    (required, on gradle-quality-plugin/ changes)
  │    └─ ./gradlew build test detekt ktlintCheck
  │
  ├─ workflow-lint      (required, always)
  │    ├─ actionlint on all .github/workflows/*.yml
  │    └─ bash -n on all .github/scripts/*.sh
  │
  ├─ security           (required, always)
  │    └─ validate-github-action-refs.sh (resolvable external refs)
  │
  ├─ consumer-verify    (scope-driven: only on workflow/action changes)
  │    └─ octopus-test canary: rewrite refs → push → wait for Merge Gate
  │
  └─ gate/merge         (aggregates all above — must be green to merge)
```

## Release Pipeline

```
workflow_dispatch (increment-version-level, target-ref)
  │
  ├─ calculate-version    (tag calculation, dry-run support)
  │
  ├─ publish-quality-plugin (Sonatype publish, only after version calculated)
  │    └─ ./gradlew build publishToSonatype closeAndRelease -Pversion=X.Y.Z
  │
  ├─ create-release       (GitHub Release + tag, only after publish succeeds)
  │
  └─ register-release-in-log (octopus-release-log registration)
```
