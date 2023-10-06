# Repository creation

- Create new public repository, see Naming Conventions
  - Add files: .gitignore, LICENSE, README.md
- About section
  - Add topics, see section 'Repository topics'
- Issues -> Labels
  - Add label 'build', color: #7E4442
- Repository settings
  - General
    - Pull Requests
      - Disable 'Allow merge commits'
      - Enable 'Automatically delete head branches'
  - Branches
    - Add branch protection rule
      - name: 'main'
        - Enable 'Require a pull request before merging'
          - Enable 'Dismiss stale pull request approvals when new commits are pushed'
          - Enable 'Require review from Code Owners'
        - Enable 'Require linear history'
        - Enable 'Do not allow bypassing the above settings'
  - Actions
    - General
      - Workflow permissions
        - Enable 'Read and write permissions'
  - Environments
    - Create environments: Prod, Test
      - See 'Environment settings' for configuration
  - Collaborators
    - Add team members
    - Add technical user 'gh-octopusden'
      - Sign in to GitHub with gh-octopusden user and accept the invitation

# Repository topics

List of commonly used topics:
* maven - maven build is used
* gradle - gradle build is used
* sonatype-nexus - module is published in Sonatype Nexus
* docker - docker image is built and published in GH packages
* public-flow - public flow module
* hybrid-flow - hybrid flow module
* pypi-package - python module published to pypi.org

# Environment settings

## Secrets

|Module topic|Prod|Test|
|---|---|---|
|sonatype-nexus|OSSRH_USERNAME| - |
|sonatype-nexus|OSSRH_TOKEN| - |
|sonatype-nexus|SONATYPE_PROFILE_ID| - |
|sonatype-nexus|GPG_PASSPHRASE| - |
|sonatype-nexus|GPG_PRIVATE_KEY| - |
|pypi-package|PYPI_API_TOKEN|PYPI_API_TOKEN|
|*|OCTOPUS_GITHUB_TOKEN| - |

## Variables

|Module topic|Prod|Test|
|---|---|---|
|pypi-package|PYPI_REPO_URL = `https://upload.pypi.org/legacy/`|PYPI_REPO_URL = `https://test.pypi.org/legacy/`|

# Create a project

- User the same name as a repository
- Use 'board' layout
- Project workflows
  - Enable all statuses except 'Auto-archive items'
- Project settings
  - Visibility: public
  - Manage access
  - Invite collaborators: add team members
- Link the project to the corresponding repository


  
