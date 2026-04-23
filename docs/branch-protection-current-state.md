# Branch Protection Baseline Snapshot

**Captured:** 2026-04-16
**Purpose:** Pre-rollout baseline for Step 2.1 of the merge-gate quality gates initiative.
**Scope:** Classic branch protection state and active check-context names across octopusden JVM repos.

> **Note:** The classic branch protection API requires admin-level access. Queries with
> a non-admin token return HTTP 403/404. All data below was captured using the `octopusden`
> admin account's fine-grained PAT with `Administration: read` permission.

---

## Summary: Classic Branch Protection State

Classic branch protection **is configured** on `main` for octopusden repos. The configuration
is uniform across repos — same settings everywhere.

| Setting | Value |
|---------|-------|
| Required approving reviews | **2** |
| Dismiss stale reviews | **yes** |
| Require code owner review | **yes** |
| Require last push approval | no |
| Enforce for admins | **yes** |
| Required linear history | **yes** |
| Allow force pushes | **no** |
| Allow deletions | **no** |
| Required conversation resolution | no |
| Required status checks | **none** |
| Required signatures | no |

**Key observations:**
- No required status checks are configured — this is what the rollout adds (`gate/merge` + `GitGuardian Security Checks`).
- `required_conversation_resolution` is `false` — the new ruleset intentionally upgrades this to `true`.
- All other settings are preserved in `jvm-strict.json` (Step 2.4).

### Mapping to ruleset rules

| Classic setting | Ruleset equivalent in `jvm-strict.json` |
|----------------|----------------------------------------|
| 2 required approvals | `pull_request.required_approving_review_count: 2` |
| Dismiss stale reviews | `pull_request.dismiss_stale_reviews_on_push: true` |
| Require code owner review | `pull_request.require_code_owner_review: true` |
| Enforce for admins | `bypass_actors: []` (no bypasses) |
| Required linear history | `required_linear_history` rule |
| No force pushes | `non_fast_forward` rule |
| No deletions | `deletion` rule |
| (new) Conversation resolution | `pull_request.required_review_thread_resolution: true` |
| (new) Status checks | `required_status_checks`: `gate/merge`, `GitGuardian Security Checks` |

---

## Active Check-Context Names (octopus-base)

Check runs were captured from PR #119
(`fix/release-sources-javadoc-validator`, head SHA `972caf8604b2d7bb693573fd0a6f357739c42013`,
merged 2026-04-15).

| Check Name | App | Conclusion |
|---|---|---|
| **`gate/merge`** | `github-actions` | success |
| `build` | `github-actions` | success |
| `quality` | `github-actions` | success |
| `security` | `github-actions` | success |
| `workflow-lint` | `github-actions` | success |
| `consumer-verify / verify` | `github-actions` | success |
| `consumer-verify-scope` | `github-actions` | success |
| `GitGuardian Security Checks` | `gitguardian` | success |

**Confirmed:** The required check-context name for the merge-gate ruleset is **`gate/merge`**.
This is the value to specify in the `required_status_checks` array when configuring rulesets
in Step 2.4.

---

## PAT Rotation Procedure

> **Note:** The PAT itself must be created and stored by the repo admin (`octopusden`).
> `octopusden` is a **User account** (not an Organization), so secrets are stored as
> repository secrets, not organization secrets.

### Why a PAT is needed

The `sync-rulesets.yml` workflow needs admin-level access to create/update rulesets on
target repos. The default `GITHUB_TOKEN` issued to Actions workflows has insufficient
privileges for ruleset management.

### Steps for the operator

1. **Create a fine-grained PAT** under the `octopusden` account.
   - Resource owner: `octopusden`
   - Repository access: all target repos (or All repositories)
   - Permissions: `Administration` (Read & Write)
2. **Store the PAT as a repository secret** named `RULESETS_ADMIN_TOKEN` in `octopus-base`
   (Settings → Secrets and variables → Actions → New repository secret).
3. **Set a rotation reminder** — recommended rotation interval: 90 days.
   Document the expiry date in the team runbook or a calendar event.
4. **Test** by triggering `.github/workflows/sync-rulesets.yml` manually via
   **Actions → Sync Repository Rulesets → Run workflow** after creation.

---

## Raw API Responses

### Branch protection (octopus-base)

<details>
<summary><code>GET /repos/octopusden/octopus-base/branches/main/protection</code></summary>

```json
{
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false,
    "required_approving_review_count": 2
  },
  "required_signatures": {
    "enabled": false
  },
  "enforce_admins": {
    "enabled": true
  },
  "required_linear_history": {
    "enabled": true
  },
  "allow_force_pushes": {
    "enabled": false
  },
  "allow_deletions": {
    "enabled": false
  },
  "block_creations": {
    "enabled": false
  },
  "required_conversation_resolution": {
    "enabled": false
  },
  "lock_branch": {
    "enabled": false
  },
  "allow_fork_syncing": {
    "enabled": false
  }
}
```

</details>

### Branch protection (octopus-components-registry-service)

<details>
<summary><code>GET /repos/octopusden/octopus-components-registry-service/branches/main/protection</code></summary>

```json
{
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false,
    "required_approving_review_count": 2
  },
  "required_signatures": {
    "enabled": false
  },
  "enforce_admins": {
    "enabled": true
  },
  "required_linear_history": {
    "enabled": true
  },
  "allow_force_pushes": {
    "enabled": false
  },
  "allow_deletions": {
    "enabled": false
  },
  "block_creations": {
    "enabled": false
  },
  "required_conversation_resolution": {
    "enabled": false
  },
  "lock_branch": {
    "enabled": false
  },
  "allow_fork_syncing": {
    "enabled": false
  }
}
```

</details>

### Check runs for PR #119 (octopus-base, SHA 972caf8604b2d7bb693573fd0a6f357739c42013)

<details>
<summary>GET check-runs — condensed</summary>

```json
{
  "total_count": 8,
  "check_runs": [
    { "name": "gate/merge",                  "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "consumer-verify / verify",    "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "security",                    "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "workflow-lint",               "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "build",                       "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "quality",                     "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "consumer-verify-scope",       "app": "github-actions", "status": "completed", "conclusion": "success" },
    { "name": "GitGuardian Security Checks", "app": "gitguardian",    "status": "completed", "conclusion": "success" }
  ]
}
```

</details>

---

## Next Steps

| Step | Description |
|---|---|
| 2.2 | Add public/internal convention + naming lint to `octopus-base` |
| 2.3 | Extract `gate/merge` composite action into reusable action |
| 2.4 | Create repo-level ruleset (evaluate mode) requiring `gate/merge` + `GitGuardian` |
| 2.4 | Store `RULESETS_ADMIN_TOKEN` as repository secret (operator action) |
| 2.5 | Switch ruleset to active; remove legacy classic protection |
| 2.6 | Sub-agent prompt templates for rolling out to consumer repos |
