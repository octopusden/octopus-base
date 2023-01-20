# Root level parameters

**Parameters**
|Parameter|Type, spec|Value|
|-|-|-|
|OCTOPUS_GITHUB_TOKEN|Password, read-only, hidden|\<call admin\>|
|OCTOPUS_GITHUB_DOCKER_REGISTRY|Text, read-only|ghcr.io/octopusden|

**SSH Keys**

Upload SSH Key:
- name: gh-octopusden
- key: \<call admin\>

# Octopus Module parameters

**VCS Roots**

- Auth method: Uploaded Key
- Username: git
- Uploaded key: gh-octopusden
- Passphrase: \<call admin\>
