# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **COMMIT CHANGES** - If you modified files, you must commit. If you only updated the backlog, do not commit.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - REVIEWER

## 1. Load Context

1. Find assigned review tasks using the backlog search tool.
   - **JQL**: `assignee = currentUser() AND status = "In Review" AND labels not in ("needs-planning", "needs-tests", "tech-debt") ORDER BY priority DESC`
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details using the backlog task detail tool.

**CRITICAL**: Check the `comment` field in the issue details.

- If there are recent comments from humans (or other agents), **READ THEM CAREFULLY**.
- New instructions in comments override the original description.

## 3. Review the Task

**Goal**: Verify the implementation is correct, clean, and tested.

1.  **Checkout**: Ensure you are on the correct branch/commit for this issue.
2.  **Run Tests**: Execute `npm run test` (or equivalent).
    - If tests FAIL: Reject immediately.
3.  **Analyze Code**: Read the changes.
    - **Logic Check**: Is the implementation correct based on the ticket description?
    - **Code Quality**: Is the code clean? Any obvious bad patterns?
    - **Test Coverage**: Are there new tests for the new feature?

## 4. Decide & Transition

Based on your analysis, choose ONE path:

### Path A: REJECT (Logic/Tests Failed)

- **Action**: Comment on the task explaining _exactly_ what failed.
- **Transition**: Move status back to **"In Progress"**.
- **Label**: (Optional) Add `ralph-failed` if it was a build error.

### Path B: MISSING TESTS (Logic Good, Tests Missing)

- **Action**: Comment "Logic looks good, but missing tests."
- **Label**: Add `needs-tests`.
- **Transition**: Move status to **"To Do"**. (This hands off to the Tester Agent).

### Path C: MESSY CODE (Functional but Ugly)

- **Action**: Comment "Functional, but needs refactoring."
- **Label**: Add `tech-debt` (and potentially `needs-refactor`).
- **Transition**: Move status to **"Done"**. (Refactorer will pick it up later).
  - _Note_: If it's really bad, use Path A instead.

### Path D: APPROVE (Good to Go)

- **Action**: Comment "Verified. Tests passed. Code looks good."
- **Transition**: Move status to **"Done"**.

## 5. Commit & Stop

If you made any changes (e.g. minor fixes, adding labels via script), commit them:

```
RALPH_REVIEWER: Reviewed <TASK-KEY> -> <DECISION>
```

If you ONLY updated the backlog:
Output `<promise>COMPLETE</promise>` immediately.

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
