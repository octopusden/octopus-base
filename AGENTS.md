# Local Workflow Contract Rules

- When changing the reusable workflow merge contract (workflow names, required checks, merge-gate semantics, or verifier expectations), update the canary or consumer tests in the same change set.
- For `octopus-base`, keep `octopus-test` verification aligned with the current contract instead of validating an outdated workflow set.

## PR Pipeline (Merge Gate)

Same base taxonomy as consumer repos plus producer-specific `consumer-verify`.

```
PR opened / pushed
  │
  │  ── Required on every PR ──
  │
  ├─ build              ./gradlew build test (gradle-quality-plugin)
  ├─ quality            ./gradlew detekt ktlintCheck (gradle-quality-plugin)
  ├─ workflow-lint      actionlint + bash -n (CI infrastructure)
  ├─ security           validate-github-action-refs.sh
  │
  │  ── Producer-specific (scope-driven) ──
  │
  ├─ consumer-verify    octopus-test canary (on workflow/action changes only)
  │
  └─ gate/merge         all above must succeed (consumer-verify noop when out of scope)
```

**Org-wide taxonomy:** `build` · `quality` · `security` · `workflow-lint` · `gate/merge`
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
