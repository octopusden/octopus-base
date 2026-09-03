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
  │    ├─ ./gradlew build publishToSonatype closeSonatypeStagingRepository -Pversion=X.Y.Z
  │    └─ .github/scripts/portal-publish.sh   (Central Portal publish — IRREVERSIBLE)
  │
  ├─ create-release       (GitHub Release + tag, only after publish succeeds)
  │
  └─ register-release-in-log (octopus-release-log registration)
```

## Reviewing a change before it is proposed

Anything that touches the release path — the reusable workflows, the scripts they call, or the
recovery around them — goes through this before a PR is opened, because a defect there is only
discovered during an incident, when nobody is watching for a regression:

1. **Self-review and fix first**, then hand the same artefact to an independent adversarial
   reviewer, then repeat. Two independent reviewers reading the real code (not the description of
   it) is the bar: the release-log ordering defect in octopus-base#189 survived four rounds of
   design review and was caught only by a reviewer who read the receiving side.
2. **Ask for findings against the code, and for the reviewer's own claims to be checkable** —
   file and line. A review that cannot be verified cannot be acted on.
3. **Apply the YAGNI lens** (`ponytail`) once the change stops growing: every guard, flag, file
   and abstraction must name a consumer that exists today. Anything that cannot is removed, and
   what remains is measured again. Applied to octopus-base#189 this removed a coordinate-deriving
   job, a provenance artefact on the hot path of every release, an allowlist, a retry budget and
   two flags — about 40% of the change, none of it with a consumer.
4. **A reviewer's finding is a claim, not an instruction.** Check it against the code before
   acting: of the findings taken in #189, several were wrong in detail and two would have broken
   the Gradle publish if applied literally.
