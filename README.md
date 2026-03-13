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

Workflow lint for this release action only:
- `Lint Release octopus-base workflow` validates `.github/workflows/check-octopus-test-consumer.yml`, `.github/workflows/release-octopus-base.yml`, `.github/workflows/verify-octopus-test-consumer.yml`, and runs `bash -n` for related helper scripts.

## Automated consumer verification in octopus-test

What this is:
- A CI gate that validates changes in `octopus-base` workflows/actions against a real consumer repository (`octopus-test`) before merge/release.
- The gate creates/updates verification branch `verify/octopus-base-pr-<PR_NUMBER>` in `octopus-test`, rewrites `octopus-base` workflow refs to the tested SHA, and waits for required consumer build workflows.
- If any required consumer workflow fails (or does not complete in time), the check fails.

How a developer uses it:
1. Open/update a PR and wait for `Merge Gate`.
2. If you need to run the same check manually, start `Actions` -> `Merge Gate` and provide optional inputs (`octopus_base_ref`, `verify_branch`, `timeout_minutes`).
3. Before cutting a release, you can run the same gate from `Release octopus-base` by setting `verify_octopus_test=true`.

Where to look for results:
- PR checks show pass/fail summary for `Merge Gate / gate/merge`.
- Detailed links to required `octopus-test` workflow runs are written into the workflow job summary.

Default path:
- Every PR triggers `Merge Gate`.
- Canary verification in `build` runs when PR changes touch `.github/workflows/**`, `.github/actions/**`, or `.github/scripts/update-octopus-test-refs.sh`.
- Release flow can run the same gate when `verify_octopus_test=true`.

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
