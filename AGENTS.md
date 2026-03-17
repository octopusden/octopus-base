# Local Workflow Contract Rules

- When changing the reusable workflow merge contract (workflow names, required checks, merge-gate semantics, or verifier expectations), update the canary or consumer tests in the same change set.
- For `octopus-base`, keep `octopus-test` verification aligned with the current contract instead of validating an outdated workflow set.
