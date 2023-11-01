:exclamation: **NOTE:** _This article needs to be revised_

## GitHub Action

### Setup a workflow trigger
    
For release:
```yaml
on:
  repository_dispatch:
    types: [ release ]
```
More [information about triggers](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow)

The workflow can be triggered by REST API. The data payload has format:
```yaml
event_type:
  type: string
  enum:
    - release
client_payload:
  type: object
  properties:
    commit:
      type: string
    project_version:
      type: string
      pattern: ^v([0-9]+)\.?([0-9]+)?\.?([0-9]+)?
```

## Jobs

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    environment: Prod
```
Where 'environment: Prod' it is an environment is used to describe a general deployment target.

## Steps

In general block 'Steps' should contain the following operations:

- Checkout and switch to a commit
- Set up JDK
- Build project
- Publish artifacts to sonatype
- Create a docker image and publish it to **ghcr.io**

## Calculate a version on the GH side

To get the version from the tag(when the version is no input parameter):
```yaml
  - uses: actions-ecosystem/action-get-latest-tag@v1
    id: tag_version
    with:
      initial_version: v2.0.0
```
[More information about this action](https://github.com/marketplace/actions/actions-ecosystem-action-get-latest-tag)

To upgrade the version:
```yaml
  - uses: actions-ecosystem/action-bump-semver@v1
    id: bump_semver
    with:
      current_version: ${{ steps.tag_version.outputs.tag }}
      level: patch
```
[More information about this action](https://github.com/actions-ecosystem/action-bump-semver)

## Publication

Publication looks like a gradle task execution. Example:

```yaml
- name: Publish
  run: ./gradlew publishToSonatype closeAndReleaseSonatypeStagingRepository -Pversion=${{ github.event.client_payload.project_version }}
  env:
    MAVEN_USERNAME: ${{ secrets.OSSRH_USERNAME }}
    MAVEN_PASSWORD: ${{ secrets.OSSRH_TOKEN }}
    ORG_GRADLE_PROJECT_signingKey: ${{ secrets.GPG_PRIVATE_KEY }}
    ORG_GRADLE_PROJECT_signingPassword: ${{ secrets.GPG_PASSPHRASE }}
    BUILD_VERSION: ${{ github.event.client_payload.project_version }}
```

To publish to the docker registry:
- login to **ghcr.io**
```yaml
    - name: Log in to Docker Hub
      uses: docker/login-action@v2
      with:
        registry: ghcr.io
        username: ${{ github.repository_owner }}
        password: ${{ secrets.GITHUB_TOKEN }}
```
- and push an image
```yaml
    - name: Push to docker registry
      run: docker push ghcr.io/$GITHUB_REPOSITORY:${{ github.event.client_payload.project_version }}
```

## Examples

- [Release workflow(non-docker)](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/release.yml)
- [Release workflow(with docker)](https://github.com/octopusden/octopus-employee-service/blob/main/.github/workflows/buildAndRelease.yml)
- [Build workflow](https://github.com/octopusden/octopus-external-systems-client/blob/main/.github/workflows/build.yml)
