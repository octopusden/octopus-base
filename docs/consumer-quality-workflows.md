# Consumer CI checks

The JVM build, static/coverage gates and security reports use the existing
`common-java-gradle-*.yml` workflows. Two additional reusable workflows support
consumers such as `octopus-external-systems-client`.

## Workflow lint

Call `common-workflow-lint.yml` with `contents: read`. It checks the caller's
workflows with actionlint 1.7.12 (including ShellCheck in the Docker image) and
parses every `.github/**/*.sh` with `bash -n`. No helper scripts are required.
Add its job to the consumer's `gate/merge` dependencies; invalid workflow syntax,
expressions and shell syntax then fail the gate. It needs no repository secrets.

The producer's `workflow-lint` job executes
`.github/scripts/test/workflow-lint-scenarios.py` against valid and invalid
consumer fixtures. Run it from the repository root with Python 3 and Docker.
For local machines without Docker, `--native-actionlint` uses an
installed actionlint 1.7.12; CI exercises the workflow's Docker invocation.

## Gradle dependency submission

Call `common-gradle-dependency-submission.yml` with `java-version` and
`contents: write` from a separate workflow triggered on default-branch pushes
and, optionally, `workflow_dispatch`. The reusable workflow also checks the
event and default branch before executing Gradle. It does not run on PRs.

The workflow uses [Gradle dependency submission](https://github.com/gradle/actions/tree/v5/dependency-submission)
with wrapper validation enabled. It does not run application tests or form part
of the PR merge gate; resolution/submission failures fail the workflow itself.

Dependency inventory does not itself enforce a vulnerability threshold or
replace CodeQL/Trivy.
