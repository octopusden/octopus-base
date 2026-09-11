# Docker Registry Configuration

* Set up Docker Registry for proxying from the external hosts (docker.io and ghcr.io)

# TeamCity Configuration

## Octopus Root project

**Name:** Octopus

### Parameters

Add parameters:

| Name                 | Value          | Description                                     |
|----------------------|----------------|-------------------------------------------------|
| OCTOPUS_GITHUB_TOKEN | \<call admin\> | Utilized by OctopusCallGitHubAction meta-runner |

### SSH Keys

Upload SSH Key:

* name: gh-octopusden
* key: \<call admin\>

### Meta-Runners

Upload Meta-Runners:

* ![OctopusCalculateBuildParameters](../teamcity.meta-runners/OctopusCalculateBuildParameters.xml)
* ![OctopusCallGitHubAction](../teamcity.meta-runners/OctopusCallGitHubAction.xml)
* ![OctopusCheckReleaseVersionIsNew](../teamcity.meta-runners/OctopusCheckReleaseVersionIsNew.xml)

Meta-runners are uploaded by hand and TeamCity keeps its own copy, so a change to one of these
files reaches a server only when someone re-uploads it there. An octopus-base release that changes
a meta-runner says so in its notes. Keep the file name on upload: the step type is the file name as
saved on the server.

`OctopusCalculateBuildParameters` reads `.release-line` from the checkout root to decide the
version (see [Developer Guide, Release lines](Octopus%20Developer%20Guide.md#release-lines)).
A repository without the file keeps the previous rule, newest `v*` tag plus one patch, so the
meta-runner can be re-uploaded before the file exists anywhere.

It also binds `%teamcity.build.branch.is_default%`, to apply the backwards check on the default
branch only, which is why every VCS root needs a branch specification (see
[VCS Root](#vcs-root)).

## Octopus Module project

### TeamCity project name

For Octopus modules in TeamCity, use the following naming convention:

`[h/p] module-name-without-octopus-prefix`

where:
- h - hybrid flow module
- p - public flow module

Examples:
- [h] employee-service
- [h] vcs-facade
- [p] api-gateway
- [p] config-server
 
### VCS Root

* Auth method: Uploaded Key
* Username: git
* Uploaded key: gh-octopusden
* Passphrase: \<call admin\>
* Branch specification: `+:refs/heads/*`

The branch specification is not optional. Without one TeamCity does not define
`teamcity.build.branch.is_default`, and `OctopusCalculateBuildParameters` binds that parameter to
decide whether the release-line backwards check applies. An undefined parameter reference is an
implicit agent requirement, so such a configuration would queue with no compatible agent instead
of failing.

### Parameters

Add parameters:

| Name                      | Value                        | Description                                                                       |
|---------------------------|------------------------------|-----------------------------------------------------------------------------------|
| OCTOPUS_REPOSITORY_NAME   | \<VCS Root repository name\> | Utilized by OctopusCallGitHubAction meta-runner (only for hybrid-flow components) |
