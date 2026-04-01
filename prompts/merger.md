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

Use the `ralph_merger_verify` tool with the PR number. It returns:
- `canMerge`: clear yes/no
- `blockers[]`: list of reasons if not mergeable (conflicts, CI failures, missing approval, unresolved threads, draft status)

If `canMerge` is false → `<promise>COMPLETE</promise>` (do NOT comment — the guard will re-check on the next poll once CI finishes).

**Exception**: If blockers include merge conflicts or unresolved review threads, comment why — those won't self-resolve.

## 2. Merge

Use the `ralph_merger_merge` tool with the PR number. The tool automatically:
- Verifies all conditions (rejects if not met)
- Squash-merges and deletes the branch (enforced — cannot be overridden)
- Retargets child PRs (stacked PRs) to the default branch
- Transitions the Jira issue to "Done" with a merge comment
- Checks parent subtasks — closes parent if all subtasks are Done

If merge fails → comment with reason.

## 3. Done

`<promise>COMPLETE</promise>`
