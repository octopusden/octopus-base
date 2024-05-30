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

`${DOCKER_REGISTRY_HOST}/${REPOSITORY_OWNER}/${REPOSITORY_NAME}:${BRANCH_OR_RELEASE_TAG}`

where:
- *DOCKER_REGISTRY_HOST*: the registry to deploy image to. Currently `ghcr.io`.
- *REPOSITORY_OWNER*: the owner of the source repository, that is: **octopusden** always.
- *REPOSITORY_NAME*: the short repository name the image is build from.
- *BRANCH_OR_RELEASE_TAG*: the branch image is build from for development versions (short name, without `/refs/...` prefixes), or version tag for releases:
    - **Have to be free from extra garbage and spaces**. This means:
        - Use `X.Y.Z` fromat for release tags, where *X, Y* and *Z* are integers. **Do NOT** use extra prefixes like `v.`, `ver.` and so on.
        - **Do NOT** use space characters in branch names.
    - The most recent release have to be pushed with `latest` tag suffix in this position also.
