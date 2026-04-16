# Branch Protection via Repository Rulesets

This document describes how the `jvm-strict` GitHub repository ruleset is managed, what it enforces, and how to opt repos in or out.

## What `jvm-strict` Enforces

The ruleset targets the **default branch** of each enrolled repository and enforces the following rules:

| Rule | Detail |
|---|---|
| **Pull request reviews** | 2 approving reviews required before merge |
| **Code-owner review** | At least one approval must come from a code owner |
| **Stale review dismissal** | Approvals are dismissed when new commits are pushed |
| **Thread resolution** | All review comment threads must be resolved before merge |
| **Required status checks** | `gate/merge` and `GitGuardian Security Checks` must pass |
| **Linear history** | Merge commits that rewrite history are blocked |
| **No force-push** | `non_fast_forward` rule prevents rewriting history |
| **No branch deletion** | The default branch cannot be deleted |

## Evaluate vs Active Mode

The ruleset is initially deployed in **evaluate (shadow) mode** (`"enforcement": "evaluate"`). In this mode:

- Rules are evaluated but **not enforced** — PRs and pushes are not blocked.
- Violations are visible in the GitHub UI under _Insights → Rule insights_ for each repository.
- This allows teams to observe compliance before hard enforcement begins.

When the rollout is ready to enforce, update the `enforcement` field in `jvm-strict.json` to `"active"` and merge to `main`, then manually trigger the `sync-rulesets` workflow. The sync will propagate the change to all enrolled repos.

## Opting a Repo In

1. Open a PR against `octopus-base` `main` branch.
2. Add one line to `.github/rulesets/jvm-strict.targets.txt`:
   ```
   octopusden/<repo-name>
   ```
3. Get the PR approved and merged.
4. Trigger the `sync-rulesets` workflow manually via **Actions → Sync Repository Rulesets → Run workflow**. The push trigger is disabled during initial rollout; after the rollout stabilizes, it will be enabled for automatic sync on merge.

The token used (`RULESETS_ADMIN_TOKEN`) must have admin access to the target repository.

## Opting a Repo Out

Opting out is a two-step process:

**Step 1 — Stop future syncs.** Remove the repo line from `jvm-strict.targets.txt` via a PR. Once merged, the workflow will no longer touch that repo.

**Step 2 — Remove the existing ruleset.** Find the ruleset ID and delete it:

```bash
# List rulesets to find the ID
gh api repos/octopusden/<repo-name>/rulesets --jq '.[] | select(.name == "jvm-strict") | {id, name}'

# Delete by ID
gh api repos/octopusden/<repo-name>/rulesets/<id> --method DELETE
```

Skipping Step 2 leaves the ruleset in place on the repo even though the sync no longer manages it.

## Emergency Rollback

If the ruleset causes unexpected issues across all repos, perform a full rollback:

### Option A — Switch back to evaluate mode (preferred)

1. Edit `jvm-strict.json`: change `"enforcement": "active"` → `"enforcement": "evaluate"`.
2. Merge to `main`, then manually trigger the `sync-rulesets` workflow via **Actions → Sync Repository Rulesets → Run workflow**. The sync will propagate the change to all enrolled repos.

### Option B — Remove the ruleset from all repos

Run the following script locally with a token that has admin access:

```bash
export GH_TOKEN="<your-admin-token>"
while IFS= read -r repo; do
  [[ -z "${repo}" || "${repo}" == \#* ]] && continue
  id="$(gh api "repos/${repo}/rulesets" --jq '.[] | select(.name == "jvm-strict") | .id' 2>/dev/null)" || true
  if [[ -n "${id}" ]]; then
    echo "Deleting ruleset ${id} from ${repo}"
    gh api "repos/${repo}/rulesets/${id}" --method DELETE
  fi
  sleep 1
done < .github/rulesets/jvm-strict.targets.txt
```

After the emergency is resolved, restore the ruleset by re-merging `jvm-strict.json` (or updating enforcement mode) so the sync workflow recreates it.

## Sync Workflow Details

The `sync-rulesets.yml` workflow (`Sync Repository Rulesets`) currently runs on:
- Manual trigger via `workflow_dispatch` only

> **Note:** The push trigger (on changes to `.github/rulesets/**`) is commented out during initial rollout to ensure the first sync is operator-controlled. After validating evaluate-mode behavior, uncomment the push trigger in `sync-rulesets.yml` to enable automatic sync on merge.

It requires the `RULESETS_ADMIN_TOKEN` repository secret. Archived repositories are automatically skipped. Failures per repo are accumulated and reported at the end; the job exits non-zero if any repo fails, so CI is red but all repos are attempted.
