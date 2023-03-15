# Setup

1. Create GitHub account
2. Ask the project owner to add you to the Octopus contributor list for the required repositories
3. For each cloned repository, set your private email via the command 'git config --local user.email <your_private_email>', to avoid commits made by corporate domain users

# Contribution policies

- For each change, create a feature branch (direct commit to the 'main' branch is forbidden)
- For each change, create an issue in the corresponding project (issue #id must be put in a pull request description)
  - it's allowed to avoid issue creation for primitive changes (typos, formatting, etc), but please specify project explicitly in order to view this pull request on the project board
- Use naming conventions for branches and pull requests (see below)
- Merge with squash strategy (merge&commit strategy is forbidden in order to keep linear history)

# Naming Conventions

## Repository names

- lowercase
- hyphen as a delimiter
- 'octopus-' prefix

Template: 'octopus-abc-def'
Examples: 'octopus-parent', 'octopus-versions-api'

## Project names

Project name is the same as a repository name

## Branch names

- issue_id-brief-description: if there is an issue for the change
- brief-description: if there is no issue (primitive change)

Examples: 13-fix-npe-on-start, 12-support-security-champ, fix-typo

## Pull Request names

Specify the issue id in the PR description, e.g. '#123'. 
Use GitHub keywords to automatically close the related issue, for example 'fixes #123' or 'closes #123'. See https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/using-keywords-in-issues-and-pull-requests

## Group Id, Artifact Id

- groupId should start with `org.octopusden.octopus.` prefix.
  - For example: groupId = `org.octopusden.octopus.employee`, groupId = `org.octopusden.octopus.vcsfacade`.
- artifactId may optionally include `octopus` prefix if it is meaningful.
  - For example: artifactId = `octopus-parent`, artifactId = `cloud-commons`.

## Package names

Package name should start with `org.octopusden.octopus.` prefix.