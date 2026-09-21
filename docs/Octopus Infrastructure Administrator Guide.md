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

Both `OctopusCalculateBuildParameters` and `OctopusCheckReleaseVersionIsNew` run bash, which a
Command Line runner cannot execute on a Windows agent: TeamCity writes the script as a `.cmd` and
`cmd.exe` reads the shebang as a command name, so the step exits 255 having run none of the
logic. `OctopusCalculateBuildParameters` therefore excludes Windows agents; the other does not
need to, and the reasoning for both is in
[ADR 0009](adr/0009-meta-runner-scripts-are-bash-on-posix-agents.md), which also gives the
post-upload verification — a property to check, not an agent count to compare, because the pool
size changes on its own.

The bash scripts embedded in these two files carry **every `%` doubled**. TeamCity collapses `%%`
to one `%` inside `script.content`, so an unescaped script reaches the agent altered; this
silently turned `${var%%pattern}` into `${var%pattern}` and broke version calculation in 2026-09.
Regenerate an embedded copy with `sed 's/%/%%/g' teamcity/scripts/<script>.sh` rather than
pasting the script as-is; the test suites check it. (The Kotlin `scriptContent` blocks are
subject to the same resolution but contain no `%` today, and nothing checks them.)

`OctopusCalculateBuildParameters` reads `.release-line` from the repository root to decide the
version (see [Developer Guide, Release lines](Octopus%20Developer%20Guide.md#release-lines) for
the rule). A repository that does not have the file yet keeps working, so the upload need not wait
for any repository to adopt it.

It also binds `%teamcity.build.branch.is_default%`, to apply the backwards check on the default
branch only, which is why every VCS root needs a branch specification (see
[VCS Root](#vcs-root)).

Both values reach the step as **environment variables**, declared as `env.` parameters of the
meta-runner itself. That is the only declaration that works: an `env.` parameter written inside a
build step is an unknown runner setting, which TeamCity ignores without a word, and the step then
runs with nothing set. If a build stops with

```
build.counter is not a number: ''
```

the server's copy of the meta-runner predates that declaration — re-upload it, which is enough on
its own: a meta-runner's parameters apply at build time, so configurations that already carry the
step need no change. `OctopusCheckReleaseVersionIsNew` reports the same cause as
`LAST_RELEASE_VERSION is not set`, and a missing branch verdict as
`teamcity.build.branch.is_default is not true or false`.

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
