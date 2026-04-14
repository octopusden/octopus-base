# Local Workflow Contract Rules

- When changing the reusable workflow merge contract (workflow names, required checks, merge-gate semantics, or verifier expectations), update the canary or consumer tests in the same change set.
- For `octopus-base`, keep `octopus-test` verification aligned with the current contract instead of validating an outdated workflow set.

## PR Pipeline (Merge Gate)

Uses the same base taxonomy as consumer repos (`build`, `quality`, `security`)
plus producer-specific `consumer-verify` for octopus-base.

```
PR opened / pushed
  │
  ├─ build              (on gradle-quality-plugin/ changes)
  │    └─ ./gradlew build test
  │
  ├─ quality            (on gradle-quality-plugin/ changes)
  │    └─ ./gradlew detekt ktlintCheck
  │
  ├─ workflow-lint      (always)
  │    ├─ actionlint on all .github/workflows/*.yml
  │    └─ bash -n on all .github/scripts/*.sh
  │
  ├─ security           (always)
  │    └─ validate-github-action-refs.sh
  │
  ├─ consumer-verify    (producer-specific, on workflow/action changes)
  │    └─ octopus-test canary: rewrite refs → push → wait for Merge Gate
  │
  └─ gate/merge         (aggregates all above — skipped jobs OK, failures block)
```

**Consumer repo target taxonomy:** `build` → `quality` → `security` → `workflow-lint` → `gate/merge`
**octopus-base adds:** `consumer-verify` (producer layer)

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
