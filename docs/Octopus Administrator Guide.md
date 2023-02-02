# Repository creation

- Create new public repository, see Naming Conventions
  - Add files: .gitignore, LICENSE, README.md
- Repository settings
  - General
    - Pull Requests
    - Disable 'Allow merge commits'
    - Enable 'Automatically delete head branches'
  - Collaborators
    - Add team members
    - Add technical user 'gh-octopusden'
      - Sign in to GitHub with gh-octopusden user and accept the invitation
  - Branches
    - Add branch protection rule
      - name: 'main'
        - Enable 'Require a pull request before merging'
          - Enable 'Dismiss stale pull request approvals when new commits are pushed'
          - Enable 'Require review from Code Owners'
        - Enable 'Require linear history'
        - Enable 'Do not allow bypassing the above settings'
  - Environments
    - New Environment
      - name: 'Prod'
        - Add secrets: OSSRH_USERNAME, OSSRH_TOKEN, SONATYPE_PROFILE_ID, GPG_PASSPHRASE, GPG_PRIVATE_KEY

# Create a project

- User the same name as a repository
- Use 'board' layout
- Project workflows
  - Enable all statuses except 'Auto-archive items'
- Project settings
  - Visibility: public
  - Manage access
  - Invite collaborators: add team members
  
