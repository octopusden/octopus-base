# Sub-Agent Playbook: Post-Merge Verifier

## Purpose

After a quality-gates PR merges to `main`, confirm that the repository is correctly
configured: the branch ruleset is active, the `gate/merge` check-run appears in CI,
and (optionally) a smoke PR demonstrates that merging is actually blocked when the
gate fails.

## Parameters (filled in by the orchestrator)

| Placeholder       | Example value   | Meaning                        |
|-------------------|-----------------|--------------------------------|
| `{{REPO_OWNER}}`  | `octopusden`    | GitHub organisation or user    |
| `{{REPO_NAME}}`   | `octopus-release-plugin` | Repository name      |

---

## Step 1 — Confirm ruleset exists

Run:

```bash
gh api repos/{{REPO_OWNER}}/{{REPO_NAME}}/rulesets
```

Expected: the JSON array contains an entry whose `name` is `jvm-strict` and whose
`enforcement` is either `"active"` or `"evaluate"` (evaluate is acceptable during
the rollout; active is the target state).

**FAIL** conditions:
- The array is empty.
- No entry with `name == "jvm-strict"` exists.

---

## Step 2 — Confirm `gate/merge` appears in check-runs on the PR head commit

> **Why the PR head commit, not the merge commit?**
> `gate/merge` is defined with `on: pull_request`, so GitHub attaches its check-runs to
> the PR's head commit — not to the merge commit that lands on `main`.  Querying
> the merge commit's check-runs will always return an empty list for this check.

Obtain the head SHA of the most recently merged PR:

```bash
PR_HEAD_SHA=$(gh pr list \
  --repo {{REPO_OWNER}}/{{REPO_NAME}} \
  --state merged --limit 1 \
  --json headRefOid \
  --jq '.[0].headRefOid')
```

Then list check-runs for that commit:

```bash
gh api repos/{{REPO_OWNER}}/{{REPO_NAME}}/commits/${PR_HEAD_SHA}/check-runs \
  --jq '.check_runs[].name'
```

Expected: the output contains `gate/merge` on its own line.

**FAIL** conditions:
- `gate/merge` is absent from the list.
- The check-run list is empty (workflows may not have run yet — wait up to 3 minutes and retry once).

Also verify that the `gate/merge` check-run concluded with `conclusion == "success"`:

```bash
gh api repos/{{REPO_OWNER}}/{{REPO_NAME}}/commits/${PR_HEAD_SHA}/check-runs \
  --jq '.check_runs[] | select(.name == "gate/merge") | .conclusion'
```

Expected output: `"success"`

---

## Step 3 — Smoke PR (optional but recommended)

This step verifies the blocking contract end-to-end. Two variants — pick one:

**Variant A (timing-free, recommended):** attempt merge **immediately** after
PR creation, before `gate/merge` has a chance to complete. Required status
checks are enforced regardless of outcome — merge must be blocked while the
check is missing or pending.

1. Create a trivial branch off `main` and open the PR:

   ```bash
   git checkout -b chore/smoke-test-gate-{{REPO_NAME}}
   # make a no-op change, e.g. add a blank line to README
   git commit -m "chore: smoke test — delete this PR"
   git push -u origin chore/smoke-test-gate-{{REPO_NAME}}
   pr_url="$(gh pr create --title "chore: smoke test (delete me)" \
                --body "Automated smoke test for gate/merge blocking." \
                --base main)"
   pr_number="$(echo "$pr_url" | grep -o '[0-9]*$')"
   ```

2. **Immediately** (do not wait) attempt to merge via the API:

   ```bash
   merge_output="$(gh api repos/{{REPO_OWNER}}/{{REPO_NAME}}/pulls/${pr_number}/merge \
     --method PUT --field merge_method=squash 2>&1 || true)"
   echo "${merge_output}"
   ```

   Expected: the API returns HTTP 405 / 409 with a message referencing required
   status checks (e.g. "Required status check 'gate/merge' is expected" or
   "Pull Request is not mergeable"). If the API returns success, the ruleset is
   NOT enforcing — this is a FAIL.

3. Cleanup:

   ```bash
   gh pr close "$pr_number" --delete-branch --repo {{REPO_OWNER}}/{{REPO_NAME}}
   ```

**Variant B (deterministic failure):** deliberately break a required check so
`gate/merge` goes red, then attempt merge. Use this when Variant A is
inconclusive (e.g., checks complete too fast in small repos).

1. Create a branch with a deliberate violation (e.g., introduce a detekt error
   or a failing unit test — repo-specific, pick something the quality gate
   will reject).

2. Push, open PR, wait for `gate/merge` conclusion to be `failure`:

   ```bash
   gh pr view "$pr_number" --json statusCheckRollup --jq \
     '.statusCheckRollup[] | select(.name == "gate/merge") | .conclusion'
   ```

3. Attempt to merge and expect the API to reject:

   ```bash
   gh api repos/{{REPO_OWNER}}/{{REPO_NAME}}/pulls/${pr_number}/merge \
     --method PUT --field merge_method=squash 2>&1 | grep -iE "blocked|required status|not mergeable"
   ```

4. Cleanup as in Variant A.

---

## Output Format

Emit one of the following verdicts.

### PASS

```
PASS

Step 1: ruleset `jvm-strict` found (enforcement: evaluate).
Step 2: `gate/merge` check-run present on PR head commit <sha> with conclusion `success`.
Step 3: smoke PR blocked as expected.
```

### FAIL

```
FAIL

Step 2: `gate/merge` check-run not found on PR head commit abc1234.
  → Workflow may not have triggered. Check Actions tab:
    https://github.com/{{REPO_OWNER}}/{{REPO_NAME}}/actions

Remediation:
  - Verify .github/workflows/merge-gate.yml has `on: pull_request` trigger.
  - Re-run the failing workflow manually if needed.
```

Provide the relevant GitHub Actions URL and the exact failing assertion so the
operator can act without additional investigation.
