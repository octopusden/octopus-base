# Expied private key
## Symptoms

Public components Release fails at the step of artifact signature with error:

```bash
gpg: no default secret key: No secret key
gpg: signing failed: No secret key
[INFO] ------------------------------------------------------------------------
[INFO] Reactor Summary for Octopus Jira Utils Library 2.0.15:
[INFO] 
[INFO] Octopus Jira Utils Library ......................... FAILURE [ 10.061 s]
[INFO] common ............................................. SKIPPED
[INFO] helper-services .................................... SKIPPED
[INFO] components-registry ................................ SKIPPED
[INFO] ------------------------------------------------------------------------
[INFO] BUILD FAILURE
[INFO] ------------------------------------------------------------------------
[INFO] Total time:  15.415 s
[INFO] Finished at: 2025-02-14T18:12:52Z
[INFO] ------------------------------------------------------------------------
Error:  Failed to execute goal org.apache.maven.plugins:maven-gpg-plugin:3.0.1:sign (sign-artifacts) on project jira-utils-parent: Exit code: 2 -> [Help 1]
```

This error is likely to indicate that the public key used for signature is expired.

## Check key expiration date

1. Take private key from the Vault and save it as `private_key.asc`.
2. Import the key to local keyring, enter passphrase from Vault to import the key.
```bash
gpg --import private_key.asc
```
3. Check the expiration date of the public key used for signature:
```bash
gpg --list-keys --keyid-format=long
```
```
sec   rsa4096/ABCDEF1234567890 2023-01-01 [C]
      Key fingerprint = XXXX XXXX XXXX XXXX XXXX  XXXX XXXX XXXX XXXX XXXX
uid           [ultimate] Your Name <email@example.com>
ssb   rsa4096/1234567890ABCDEF 2023-01-01 [S]
```
4. If the key is active and no further actions are required, delete the key from local keyring:
```bash
gpg --delete-secret-keys KEY-ID
gpg --delete-key KEY-ID
```
5. Ensure that the key is deleted:
```bash
gpg --list-keys --keyid-format=long
```

## Solution (renew the key)

> **Note:** Sonatype repository is attached to the user ID, and regenerating the key with another name and email will cause an error at the deployment stage to Sonatype Nexus.

### Renew the key

1. Edit the key:
```bash
gpg --edit-key KEY-ID
```
2. Edit expiration date:
```bash
expire
```
3. Enter validity period, for example, 2 years: `2y`.
4. Change passphrase:
```bash
passwd
```
5. Save changes:
```bash
save
```
6. Check the key expiration date:
```bash
gpg --list-keys --keyid-format=long
```
7. Export updated key:
```bash
gpg --export-secret-keys --armor KEY_ID > updated-private-key.asc
```
8. Delete the key from your local keyring:
```bash
gpg --delete-secret-keys KEY-ID
gpg --delete-key KEY-ID
```
9. Ensure that the key is deleted:
```bash
gpg --list-keys --keyid-format=long
```

### Test the key

1. As Octopus administrator open settings of the [octopus-test](https://github.com/octopusden/octopus-test) repository.
2. Go to **Environments**.
3. Select `Prod` environment.
4. Update `GPG_PASSPHRASE` and `GPG_PRIVATE_KEY`.
5. Open **Actions** tab.
6. Find **Release Maven Public** workflow at leftside panel.
7. Run the workflow from the main branch.

### Add new key to Vault

After testing the updated configuration, add the new key and passphrase to the Vault by creating a new version of the secret.

### Update repositories configuration

1. Find all repositories with the label ['sonatype-nexus'](https://github.com/octopusden?tab=repositories&q=sonatype-nexus&type=&language=&sort=).
2. Update the configuration by changing `GPG_PASSPHRASE` and `GPG_PRIVATE_KEY` in the same way as for `octopus-test` in the [Key testing](#test-the-key) section.

# Release refused with "Built commit cannot be tagged"

## Symptoms

A release fails early, before the build, with `Built commit cannot be tagged` and a list of
workflow file names. Nothing was published.

On repositories still using the older `OctopusCallGitHubAction` metarunner the symptom looks
completely different: that metarunner only polls for the GitHub *release* to appear — not the
tag — so a refused release shows up as a wait of `OCTOPUS_RELEASE_TIMEOUT` minutes ending in
`Number of attempts exceeded`, with no hint of the real cause. The distinction matters beyond
this failure: the pipeline has paths that create the tag and then fail before the release, and
those look identical to a refused release from the metarunner's side. The newer
`CallGitHubRelease.main.kts` reports the failing run and its reason directly. If you see the
timeout, open the GitHub Actions run for that release and read the failed step.

## Cause

The release tags the commit it builds. GitHub refuses to point a tag at a commit carrying a
workflow file that exists on no branch head, unless the token may modify workflows — which the
Actions `GITHUB_TOKEN` never may. **This is not about the code being released:** it is usually
triggered by someone editing `.github/workflows/` on the default branch after the commit being
released, including the routine bumps of reusable-workflow pins.

The release checks this before building precisely so the alternative does not happen: publishing
an immutable version to Maven Central and only then failing with no tag.

## What to do

1. Release from a branch tip instead — any branch head is taggable, including a maintenance
   branch whose workflow files legitimately differ from the default branch.
2. Or release a commit whose `.github/workflows` are unchanged relative to some branch head.
3. Only if this specific historical commit must be released: create the tag manually — but read
   the credential note below first, because this is not something an ordinary operator can do.

### The credential this needs, which the org does not currently provision

Creating a tag on such a commit requires a credential **authorized to modify workflows**: a PAT
with `workflow` scope, or a GitHub App with `Workflows: write`. The Actions `GITHUB_TOKEN` can
never have it, and no personal token has it by default — a classic PAT with `repo` scope alone is
refused exactly like the workflow is.

At the time of writing the org has **not** decided to provision such a credential; that is an
open question in `octopus-base` — the failing step's error message states the rule and the two
workable remedies, but carries no issue link. So treat
"create the tag manually" as requiring an administrator to mint a suitable token first. Do not
plan a release around this recovery — prefer options 1 and 2 above.

## The rarer variant, after publishing

If instead the release fails at `Tag creation refused` *after* publishing, the property that made
the built commit taggable was withdrawn while the release was building. Two ordinary events do
that:

- a workflow change merged to a branch, so the built commit's workflow files no longer match any
  branch head;
- **the branch whose tip was being released was advanced or deleted** — GitHub deletes branches on
  merge by default, so this is routine rather than a rare race. A commit that was legal *because*
  it headed a branch stops being legal when that branch goes away.

The artifacts are published and immutable, so the version cannot be republished. **Do not
re-dispatch the release** — that would start a fresh run which tries to publish the same version
and fails.

Recovery, in this order:

1. Create the tag on the commit the run built — the failing step prints both the tag name and the
   commit sha. This needs the credential described above, so unless an administrator has minted
   one, escalate here.
2. On the same run, use GitHub's **"Re-run failed jobs"**. Tagging and release creation live in
   their own job (`Tag and release`), downstream of the publish, so a re-run repeats only that
   job: it finds the tag now present on the built commit, attaches the release to it, and leaves
   the successful publish untouched.

That job split is what makes step 2 work at all. Before it existed, publishing and tagging shared
one job, so any re-run replayed the publish and failed on Central's immutability before ever
reaching the tag — the recovery was undocumentable in practice.
