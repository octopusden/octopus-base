### Global requirements

* Set up Docker Registry for proxying from the external hosts (docker.io and ghcr.io)



# Octopus Root project

## SSH Keys

Upload SSH Key:

* name: gh-octopusden
* key: \<call admin\>

## Meta-Runners

Upload Meta-Runners:

* ![OctopusCalculateBuildParameters](../teamcity.meta-runners/OctopusCalculateBuildParameters.xml)
* ![OctopusCallGitHubAction](../teamcity.meta-runners/OctopusCallGitHubAction.xml)

## Parameters

Add parameters:

| Name                 | Value          | Description                                     |
|----------------------|----------------|-------------------------------------------------|
| OCTOPUS_GITHUB_TOKEN | \<call admin\> | Utilized by OctopusCallGitHubAction meta-runner |



# Octopus Module project

## VCS Root

* Auth method: Uploaded Key
* Username: git
* Uploaded key: gh-octopusden
* Passphrase: \<call admin\>

## Parameters

Add parameters:

| Name                 | Value             | Description                                     |
|----------------------|-------------------|-------------------------------------------------|
| OCTOPUS_REPOSITORY   | \<VCS Root repo\> | Utilized by OctopusCallGitHubAction meta-runner |
