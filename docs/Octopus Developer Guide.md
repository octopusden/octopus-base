# Setup

1. Create GitHub account
2. Ask the project owner to add you to the Octopus contributor list for the required repositories
3. For each cloned repository, set your private email via the command 'git config --local user.email <your_private_email>', to avoid commits from corporate domain accounts

# Contribution policies

- For each change, create a feature branch (direct commit to the 'main' branch is forbidden)
- Use naming conventions for branches and pull requests (see below)
- Merge with squash strategy (merge&commit strategy is forbidden in order to keep linear history)
- For pull requests, specify additional parameters on the right sidebar: assignee, linked project, labels (Documentation, Bug, Enhancement, etc)

## Additional policies for Python code

- All Python code have to be packaged properly and installable with `pip` routine from `PyPI`. 
- Repository have to be labeled with `pypi-package`.
- The way recommended to run high-level code: `python -m <module_name>`.
- The way recommended to run unit-tests: `python -m unittest discover -v`.

## Additional policies for general Docker image-only code

- Please use `ENTRYPOINT` directive for runnable images to start a container instead of `CMD` one.

# Working with issues and pull requests

Fill in the following parameters for issues and pull requests (PR is treated the same way as issue in GitHub):
- assignee - can be multiple
- reviewers - assign only when your PR is ready for review
- project - to be visible on a project board
- labels (bug, documentation, enhancement, build, etc) - required for nice Release Notes (see the section 'How to use labels' for details)

## How to use labels

We use the following labels
- bug - fixing defects in the code of the module
- documentation - changes in documentation
- enhancement - new functionality or improvement
- build (custom) - changes in workflow actions
- dependencies (automatic) - used by dependabot, will be introduced later

# Naming Conventions

## Repository names

- lowercase
- hyphen `-` as a delimiter
- `octopus-` prefix

Template: `octopus-abc-def`
Examples: `octopus-parent`, `octopus-versions-api`

## Project names

Project name is the same as a repository name

## Branch names

- issueid-brief-description: if there is an issue for the change
- brief-description: if there is no issue 

Examples: `13-fix-npe-on-start`, `12-support-security-champ`, `fix-typo`

## Pull Request names

If there is a related issue, specify its id in the PR description, e.g. `#123`. 
Use GitHub keywords to automatically close the related issue, for example `fixes #123` or `closes #123`. See https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/using-keywords-in-issues-and-pull-requests

If the change requires specific (explicit!) actions on deploy (for example, configuration changes), please mention it in the PR description, e.g. "Requires configuration changes!".
This message will be visible in the Release Notes summary, which will help teams properly prepare to deployment.

## Group Id, Artifact Id

- **groupId** should start with `org.octopusden.octopus.` prefix.
  - For example: *groupId* = `org.octopusden.octopus.employee`, *groupId* = `org.octopusden.octopus.vcsfacade`.
- **artifactId** may optionally include `octopus` prefix if it is meaningful.
  - For example: *artifactId* = `octopus-parent`, *artifactId* = `cloud-commons`.

## Package names

Package name should start with `org.octopusden.octopus.` prefix.

## Additional rules for Python repository and package name

- `oc-` prefix on repository name.
- `oc-` prefix on package name.
- `oc_` prefix on module name.
- hyphen `-` is the delimiter for repository and package name, while underscore `_` is that for module name.
- repository name template: `octopus-oc-<sub_section>-<package_name_without_oc_prefix>`, where **sub_section** may be complex, see below.

**Possible values for *sub_section***:
- `corelibs` - for core low-level libraries used in high- and middle- level packages
- `base-libs` - for middle-level libraries used in middle- and high- level jobs but not runnable themselves
- `base-jobs` - for runnable midle-level modules (jobs)
- `srv-libs` - for high-level libraries used in high-level jobs but not runnable themselves
- `srv-jobs` - for high-level modules, runnable

**Example**:
- **Module**: `oc_sql_helpers`
- **Package**: `oc-sql-helpers`
- **Repository**: `octopus-oc-corelibs-sql-helpers`

## Additional rules for Docker images repository and tag name

Docker image may be a side-build for *Python* or *Java* package (if it is an executable module), or a general image-only build.

For *Java* and *Python* side-builds the repository and package names are described above.

For *general image-only* builds the repository name should follow the same rules as for *Python* code except that `oc-` suffix is to be replaced with `di-` one (means `Docker Image`).

It is also recommended to develop a signle image family from single repository. This means all tag part before *version separator* `:` should remain the same within images build from that repository and last part have to be different only.

Image tagging should follow the template:

`${DOCKER_REGISTRY_HOST}/${REPOSITORY_OWNER}/${DOCKER_IMAGE}:${BRANCH_OR_RELEASE_VERSION}`

where:
- *DOCKER_REGISTRY_HOST*: the registry to deploy image to. Currently `ghcr.io`.
- *REPOSITORY_OWNER*: **octopusden** always — the shared release workflow hardcodes it in the
  push target, even though it logs in as the repository's own owner.
- *DOCKER_IMAGE*: the `docker-image` input of the release workflow. It defaults to nothing and is
  **not** derived from the repository name, so a repository whose image should match its name has
  to say so explicitly.
- *BRANCH_OR_RELEASE_VERSION*: the branch the image is built from for development versions (short
  name, without `/refs/...` prefixes), or the release version:
    - **Have to be free from extra garbage and spaces**. This means:
        - Use `X.Y.Z` format for release versions, where *X, Y* and *Z* are integers. **Do NOT**
          use extra prefixes like `v.`, `ver.` and so on. Note this is the *image* tag; the git
          tag the release creates deliberately does carry a `v` prefix (`v2.0.1`).
        - **Do NOT** use space characters in branch names.

The shared release workflow pushes the image under exactly one image tag — the version. It does
**not** push a `latest` image tag; if a repository needs one, that is a manual convention, not
something the pipeline provides. (The git tag is a separate thing, always created, and unlike the
image tag it carries the `v` prefix.)

# Functional Tests In Gradle And CI

## Gradle task naming

- Canonical task name for functional/integration tests in Octopus Java services is `ft`.

## Lifecycle wiring

- Do not bind `ft` to `build`/`check` by default.
- Keep `ft` explicit and run it in dedicated workflows/jobs.
- If a repository intentionally requires FT in the default lifecycle, document this in the repository README and workflow comments.

## GitHub Actions reusable workflows

- `common-java-gradle-build` and `common-java-gradle-release` are shared across repositories, as
  are their Maven equivalents and `common-check-and-register-release`, `common-register-release`
  and `common-docker-build-deploy`. Everything matching `common-*.yml` is public API; see
  [`.github/README.md`](../.github/README.md) for the full contract and
  [Octopus Release Pipeline](Octopus%20Release%20Pipeline.md) for what the release ones do.
- Release workflow should not assume repository-specific task names.
- Use `skip-extra-tasks` in `common-java-gradle-release` only for tasks that really exist in the target repository.

Example for a repository that requires explicit `ft` exclusion:

```yaml
jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-release.yml@<tag>
    with:
      flow-type: hybrid
      java-version: '21'
      skip-extra-tasks: ft
```

Example for a repository that does not need extra exclusions:

```yaml
jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-release.yml@<tag>
    with:
      flow-type: hybrid
      java-version: '21'
```

### Which commit a hybrid release can be cut from

A release tags the commit it builds, so it can only release a commit GitHub lets it tag.
GitHub refuses to point a tag at a commit carrying a workflow file that exists on **no branch
head**, unless the token may modify workflows — which the Actions `GITHUB_TOKEN` never may. The
release therefore checks this before building and stops with the offending file names rather
than publishing a version it cannot tag.

In practice this is unrestrictive. Releasing the default-branch head, the tip of any branch
(including a maintenance branch whose workflows legitimately differ), or any commit whose
`.github/workflows` are unchanged relative to some branch head all work. What is refused is a
release of an older commit that heads no branch and whose workflow files have since changed —
re-releasing a historical commit after a workflow change landed. Cut it from a branch tip
instead, or see the token options in
[Administrator Troubleshooting](Octopus%20Administrator%20Troubleshooting.md#release-refused-with-built-commit-cannot-be-tagged).

## Maven Central publishing

> This section describes the **Gradle** release workflow. The Maven one publishes through the
> OSSRH path and has none of `publish-to-nexus`, the Central preflight, the publication guard or
> `resume-deployment-id`;
> see [Octopus Release Pipeline](Octopus%20Release%20Pipeline.md) for the differences.

Publish to Central only what other projects consume as a **Maven dependency**. Deployables
and internal tooling do not belong there:

- a service or app ships as a docker image on ghcr;
- a CLI ships as a GitHub Release asset, or is built locally;
- test harnesses and compat suites have no consumers at all.

### Keeping a repository off Central

Set `publish-to-nexus: false` **and** remove the `MavenPublication` from the build script: the
input guards the pipeline, the build-script change is what stops a manual
`./gradlew publishToSonatype`. The release still builds, pushes the docker image and creates the
GitHub release — the Sonatype publish, its secret check, the helper fetch and the publication
guard described below are skipped. Pair it with
`register-release-immediately: true`, or the release-log gate waits for an artifact that will
never appear.

```yaml
jobs:
  build:
    uses: octopusden/octopus-base/.github/workflows/common-java-gradle-release.yml@<tag>
    with:
      flow-type: hybrid
      java-version: '21'
      docker-image: my-app
      publish-to-nexus: false
      register-release-immediately: true
```

### Keeping single modules off Central

When some modules are consumed and some are not (a service plus its client libraries), declare
**no publication** for the deployable modules and keep it for the libraries. Note that
`tasks.named('publish') { enabled = false }` does **not** work — `publishToSonatype` depends on
the `PublishToMavenRepository` tasks, not on the `publish` lifecycle task.

If the module you stop publishing is the one `check-and-register.yml` polls, re-point that
workflow's `artifact-pattern` at a module that is still published.

### The publication guard

Before uploading, the release inspects what would reach Central and **fails** on:

- **a version other than the one being released** — most often Gradle's `unspecified`, which is
  its value when nothing set one. A release publishes exactly one version, and a publication at
  another version means the version properties never reached that project. Fix it by setting the
  version for every project that declares a publication (an `allprojects` / `subprojects` block,
  or the convention plugin), or by not publishing the module.

  The Portal publish step already refuses a deployment containing a foreign version — but only
  after everything has been built, signed, staged and uploaded, which leaves a staging repository
  to drop by hand. This is the same judgement, before the upload. Coordinates such as
  `unspecified` reached Central this way before the later check existed, and Central keeps them
  permanently.

  Under `dry-run: true` this one reports and continues rather than failing. A dry run has no
  upload to save, so it has nothing to gain from failing — and consumer repositories run a dry
  release as a required merge check, so a refusal there would turn a green check red on nothing
  but an `octopus-base` ref bump. The fat-jar and size rules below keep failing under dry-run, as
  they always have.

- a shadow/uber artifact (`-all` classifier);
- a Spring Boot executable jar, detected by a `BOOT-INF/` entry inside the archive — its file
  name is indistinguishable from a library's;
- anything larger than `max-central-artifact-mb` (default 8), which catches a shadow jar
  published with the classifier stripped.

A fat jar often appears without anyone asking for it: the shadow plugin exposes
`shadowRuntimeElements` as a variant of the `java` component, so `from(components.java)`
publishes the fat jar alongside the thin one.

If the guard fails your release, pick one:

| Situation | Fix |
|---|---|
| A publication carries a version other than the release version | Set the version for every project that declares a publication. There is no allowlist for this one, deliberately: `fat-jar-publication-allowlist` says an artifact may be a fat jar, which says nothing about it carrying a foreign version, and `unspecified` is a defect rather than a choice |
| The module is a deployable nobody depends on | Stop publishing it |
| The whole repository is a deployable | `publish-to-nexus: false` |
| A consumer really resolves this fat jar from a Maven repository — e.g. an automation module fetched by a TeamCity metarunner | Add its artifactId to `fat-jar-publication-allowlist` |
| A genuinely consumed library is legitimately large | Raise `max-central-artifact-mb` |

The allowlist keeps a legitimate exception explicit and reviewed instead of silent:

```yaml
      # The automation module's fat jar is resolved by its TeamCity metarunner
      # (-Dartifact=<group>:<name>:<version>:jar:all), so it must stay on Central.
      fat-jar-publication-allowlist: automation
```

The guard runs in dry-run too, so `dry-run: true` rehearses it before a real release. Callers
pin `octopus-base` by tag, so the guard starts applying to a repository only when it bumps that
ref — check what the repository publishes today and add the exception in the same PR as the bump.

### The already-published preflight

Maven Central versions are immutable, so a version that is already there can never be published
again. Before building, the release asks Central whether it already holds the version — one HEAD
per publication, against coordinates read from Gradle's own publication model at configuration
time, filtered there to the publications actually at the release version — and refuses to start
when **every** coordinate is already published.

Both halves are bounded, because a check whose whole justification is being cheaper than the
build it replaces must not be able to become expensive. The coordinate listing gets 300s — it
pays cold daemon start and full configuration, and is essentially the whole cost: on the canary
the sweep measured 0.09s and 0.07s against step totals of 9s and 13s. The HEAD sweep gets 90s in
total, and whatever is still unanswered when that runs out counts as unanswered,
which lets the release run. Exceeding either is a warning, never a failure.

That case used to surface at the very end, at `closeSonatypeStagingRepository`, after a full
build, sign, stage and upload, as:

```
Deployment reached an unexpected status: Failed
  - Component with package url: 'pkg:maven/<group>/<artifact>@<version>' already exists
```

The preflight replaces that with a statement of the situation and what to do about it. Two
situations look identical in Sonatype's message and are not:

| What the preflight finds | What it means | What to do |
|---|---|---|
| Published, and tag + GitHub release exist | The previous release published and was tagged; this dispatch resolved a stale version | Release the next version — but check `octopus-release-log` for the published version first. Registration is a separate job (`register-release-immediately`, off by default) and then a separate run gated on the release having succeeded, so the entry can be missing while the tag and release are present; #189 records a version left exactly like that. From internal CI, the manual release build takes its version from the last **finished** compile build, which can predate the previous release's bump |
| Published, but the tag or release is missing | An earlier run published and died before recording it | Recovery, not a re-dispatch — see `octopus-base#189`. Run `.github/scripts/recover-release.sh` from an `octopus-base` checkout: it completes the tag, the release and the `octopus-release-log` entry. Pass the commit that run **built** — its `Built commit` annotation names it, and the current head usually is not it |

Everything short of "all coordinates published" lets the release run, and says why in the log:

- a **partial** overlap — some coordinates published, some free — is reported as a warning, not a
  stop. It does not prove this release cannot publish, and blocking it would risk stopping a
  workable release over a publication that the real upload does not send;
- an unanswered repo1, an unlistable publication set, or a build that declares no publication
  at the release version leaves the question open, so the release proceeds exactly as it did
  before the check existed.

That asymmetry is deliberate: the preflight can only ever save a build that was going to fail,
so it must never become a new reason a valid release does not run. It is skipped when
`publish-to-nexus: false` (nothing goes to Central), when `resume-deployment-id` is set (the
version is already staged on purpose), and when the `octopus-base` helper scripts are not on
disk — the fetch that brings them is required for a real release, which cannot publish without
them, and tolerated on a dry run, which uses them for nothing else. Under `dry-run: true` the
check reports its verdict as a warning without failing.

The coordinate listing has been exercised on Gradle 7.6.4, 8.14.3 and 9.4.1, on single- and
multi-project builds, and with the configuration cache and configure-on-demand switched on in
`gradle.properties` — the release passes both off as `-D` properties, which override the file.
