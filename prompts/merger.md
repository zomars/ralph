# RULES

1. **ONE PR** — Merge one PR per iteration, then stop.
2. **VERIFY BEFORE MERGE** — Re-verify all conditions before merging.
3. **NEVER FORCE** — Never force-merge or bypass required checks.
4. **REMOVE LABEL ON FAILURE** — If a PR cannot be merged, remove the label and comment why.

---

# WORKFLOW - MERGER

## 1. Verify Merge Conditions

PR provided in user message (number, title, url, headRefName, baseRefName).
No PR → `<promise>COMPLETE</promise>`.

Fetch current state:
```bash
gh pr view <number> --json mergeable,statusCheckRollup,labels
```

Verify:
- Mergeable (no conflicts)
- CI green (all status checks passing — no `IN_PROGRESS`, `PENDING`, or `QUEUED`)
- Merge label present (`ready-to-merge`)

If ANY condition fails → `<promise>COMPLETE</promise>` (do NOT remove the label or comment — the guard will re-check on the next poll once CI finishes).

**Exception**: If the PR has merge conflicts or the label is missing, remove the label and comment why — those won't self-resolve.

## 2. Merge

```bash
gh pr merge <number> --squash --delete-branch
```

If merge fails → same failure handling as Step 1 (remove label + comment with reason).

## 3. Transition Jira to Done

After a successful merge, transition the Jira issue:

1. Extract the task key from the branch name (strip the `ralph/` prefix from `headRefName`).
2. Get available transitions for the issue using the backlog transition tool.
3. Transition the issue to **"Done"**.
4. Add a comment: `"RALPH_MERGER: Merged PR #<number> into <baseRefName>."`

If the transition fails, log it but do NOT treat it as a merge failure — the code is already merged.

## 4. Done

`<promise>COMPLETE</promise>`
