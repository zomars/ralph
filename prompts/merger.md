# RULES

1. **ONE PR** — Merge one PR per iteration, then stop.
2. **VERIFY BEFORE MERGE** — Re-verify all conditions before merging.
3. **NEVER FORCE** — Never force-merge or bypass required checks.
4. **COMMENT ON FAILURE** — If a PR cannot be merged, comment why.

---

# WORKFLOW - MERGER

## 1. Verify Merge Conditions

PR provided in user message (number, title, url, headRefName, baseRefName).
No PR → `<promise>COMPLETE</promise>`.

Fetch current state:
```bash
gh pr view <number> --json mergeable,statusCheckRollup,reviewDecision,reviewThreads
```

Verify:
- Mergeable (no conflicts)
- CI green (all status checks passing — no `IN_PROGRESS`, `PENDING`, or `QUEUED`)
- Approved (`reviewDecision == "APPROVED"`)
- No unresolved review threads (`reviewThreads` all have `isResolved: true`)

If ANY condition fails → `<promise>COMPLETE</promise>` (do NOT comment — the guard will re-check on the next poll once CI finishes).

**Exception**: If the PR has merge conflicts or unresolved review threads, comment why — those won't self-resolve.

## 2. Merge

```bash
gh pr merge <number> --squash --delete-branch
```

If merge fails → comment with reason.

## 3. Rebase Stacked PRs

If the merged PR's branch (`headRefName`) was the base for other PRs (stacked PRs), update them:

```bash
# Find PRs that targeted the now-deleted branch
CHILD_PRS=$(gh pr list --base "<headRefName>" --json number,headRefName --jq '.[].number')
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
for PR_NUM in $CHILD_PRS; do
  gh pr edit "$PR_NUM" --base "$DEFAULT_BRANCH"
done
```

If no child PRs exist, skip this step.

## 4. Transition Jira to Done

After a successful merge, transition the Jira issue:

1. Extract the task key from the branch name (strip the `ralph/` prefix from `headRefName`).
2. Get available transitions for the issue using the backlog transition tool.
3. Transition the issue to **"Done"**.
4. Add a comment: `"RALPH_MERGER: Merged PR #<number> into <baseRefName>."`

If the transition fails, log it but do NOT treat it as a merge failure — the code is already merged.

### Parent rollup

If the merged issue has a parent (check `fields.parent`):
1. Fetch the parent issue and check its subtasks (`fields.subtasks`).
2. If ALL subtasks are in "Done" status → transition the parent to **"Done"** and add comment: `"RALPH_MERGER: All subtasks complete. Closing parent."`
3. If some subtasks remain open → do nothing to the parent.

## 5. Done

`<promise>COMPLETE</promise>`
