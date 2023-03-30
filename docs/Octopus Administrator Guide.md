# Repository creation

- Create new public repository, see Naming Conventions
  - Add files: .gitignore, LICENSE, README.md
- About section
  - Add topics, e.g. 'maven', 'gradle', 'docker', 'public-flow', 'hybrid-flow', etc
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
    - New Environment
      - name: 'Prod'
        - Add secrets:
          - For maven modules: OSSRH_USERNAME, OSSRH_TOKEN, SONATYPE_PROFILE_ID, GPG_PASSPHRASE, GPG_PRIVATE_KEY
          - For python modules: PYPI_API_TOKEN
  - Collaborators
    - Add team members
    - Add technical user 'gh-octopusden'
      - Sign in to GitHub with gh-octopusden user and accept the invitation

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

  
