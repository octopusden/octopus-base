# octopus-base
Octopus project basic stuff - workflow templates, documentation, etc

---
## Documents

- [Octopus Administrator Guide](docs/Octopus%20Administrator%20Guide.md)
- [Octopus Developer Guide](docs/Octopus%20Developer%20Guide.md)
- [Octopus GitHub Actions Guide](docs/Octopus%20GitHub%20Actions%20Guide.md)
- [Octopus Infrastructure Administrator Guide](docs/Octopus%20Infrastructure%20Administrator%20Guide.md)
- [Octopus JVM Style Guidelines](docs/Octopus%20JVM%20Style%20Guidelines.md)
- [Octopus Kotlin Style Guide](docs/Octopus%20Kotlin%20Style%20Guide.md)
- [Octopus Tech Debt Register](docs/Octopus%20Tech%20Debt%20Register.md)

## Release octopus-base

Use GitHub Actions workflow `Release octopus-base`.

1. Open `Actions` -> `Release octopus-base` -> `Run workflow`.
2. Select `increment-version-level` (`patch`, `minor`, or `major`).
3. Select `target-ref` (default is `main`).
4. Optionally enable `dry-run=true` to only validate and calculate the next version.
5. Run the workflow.

The workflow:
1. Finds the latest tag in format `vX.Y.Z`.
2. Calculates the next version from the selected increment level (for example, `v2.1.10` + `patch` -> `v2.1.11`).
3. Creates GitHub Release with generated release notes (based on `.github/release.yml`) unless `dry-run=true`.
4. Registers the release in `octopus-release-log` using `common-register-release.yml` unless `dry-run=true`.

To use release registration, the `Prod` environment must contain secret `OCTOPUS_GITHUB_TOKEN`.

To use automated `octopus-test` consumer verification (`Merge Gate` on PRs and optional `verify_octopus_test` in release workflow), configure repository secret `OCTOPUS_TEST_PUSH_TOKEN`.
Note: `Prod` environment secrets are not available to `pull_request` checks unless a job explicitly uses that environment.

## PR Merge Gate

Every PR runs the `Merge Gate` workflow with the following jobs:

| Job | Always runs | What it checks |
|-----|:-----------:|----------------|
| `build` | yes | `gradle-quality-plugin`: `./gradlew build test` |
| `quality` | yes | `gradle-quality-plugin`: `./gradlew detekt ktlintCheck` |
| `workflow-lint` | yes | `actionlint` on all workflow YAML + `bash -n` on helper scripts |
| `security` | yes | External `uses@ref` validation for resolvable refs |
| `consumer-verify` | scope-driven | `octopus-test` canary (only when workflow/action files change) |
| `gate/merge` | yes | Aggregates all above — must be green to merge |

## Consumer verification in octopus-test

`consumer-verify` validates reusable workflow changes against `octopus-test` (real consumer repo):
- Creates branch `verify/octopus-base-pr-<N>` in `octopus-test`, rewrites workflow refs to PR SHA
- Waits for `octopus-test` Merge Gate to pass
- Runs only when PR changes touch `.github/workflows/**`, `.github/actions/**`, or `update-octopus-test-refs.sh`

Manual trigger: `Actions` → `Merge Gate` → provide `octopus_base_ref`, `verify_branch`.
Release trigger: `Release octopus-base` with `verify_octopus_test=true`.

Required secret:
- repository secret `OCTOPUS_TEST_PUSH_TOKEN`

## Manual fallback: consumer verification in octopus-test

Use this only for debugging or emergency verification when automation cannot be used.

1. Get the PR head SHA from `octopus-base`:
```bash
gh pr view <PR_NUMBER> --repo octopusden/octopus-base --json headRefOid -q .headRefOid
```
2. Prepare a temporary branch in `octopus-test` from `main` and rewrite refs to that SHA:
```bash
repo=/tmp/octopus-test-repo
script=/path/to/octopus-base/.github/scripts/update-octopus-test-refs.sh
branch=test/verify-octopus-base-pr<PR_NUMBER>-$(date -u +%Y%m%d-%H%M%S)
sha=<PR_HEAD_SHA>

git -C "$repo" fetch origin main
git -C "$repo" checkout -B "$branch" origin/main
bash "$script" "$repo" "$sha"
git -C "$repo" add .github/workflows
git -C "$repo" commit -m "ci: verify octopus-base PR<PR_NUMBER> $sha"
git -C "$repo" push -u origin "$branch"
```
3. Wait for required `octopus-test` workflows and check all are `success`:
```bash
gh run list -R octopusden/octopus-test --branch "$branch" --limit 20 \
  --json workflowName,status,conclusion,url
```

Required workflows:
- `Merge Gate`

Optional workflows (checked when present in `octopus-test`):
- `Quality Gates`
- `Security Reports`
