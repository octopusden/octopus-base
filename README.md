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
4. Run the workflow.

The workflow:
1. Finds the latest tag in format `vX.Y.Z`.
2. Calculates the next version from the selected increment level (for example, `v2.1.10` + `patch` -> `v2.1.11`).
3. Creates GitHub Release with generated release notes (based on `.github/release.yml`).
4. Registers the release in `octopus-release-log` using `common-register-release.yml`.

To use release registration, the `Prod` environment must contain secret `OCTOPUS_GITHUB_TOKEN`.
