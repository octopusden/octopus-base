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
