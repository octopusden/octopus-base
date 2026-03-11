# octopus-base
Octopus project basic stuff - workflow templates, documentation, etc

---
## Documents

- [Octopus Administrator Guide](docs/Octopus%20Administrator%20Guide.md)
- [Octopus Developer Guide](docs/Octopus%20Developer%20Guide.md)
- [Octopus GitHub Actions Guide](docs/Octopus%20GitHub%20Actions%20Guide.md)
- [Octopus Infrastructure Administrator Guide](docs/Octopus%20Infrastructure%20Administrator%20Guide.md)

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

To use automated `octopus-test` consumer verification (`Check octopus-test consumer` on PRs and optional `verify_octopus_test` in release workflow), configure repository secret `OCTOPUS_TEST_PUSH_TOKEN`.
Note: `Prod` environment secrets are not available to `pull_request` checks unless a job explicitly uses that environment.

Workflow lint for this release action only:
- `Lint Release octopus-base workflow` validates `.github/workflows/check-octopus-test-consumer.yml`, `.github/workflows/release-octopus-base.yml`, `.github/workflows/verify-octopus-test-consumer.yml`, and runs `bash -n` for related helper scripts.

## Automated consumer verification in octopus-test

Default path:
- PR changes in `.github/workflows/**`, `.github/actions/**`, and `.github/scripts/update-octopus-test-refs.sh` trigger `Check octopus-test consumer`.
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
- `Build Gradle Public`
- `Build Gradle Hybrid`
- `Build Gradle Hybrid Docker`
- `Build Maven Public`
