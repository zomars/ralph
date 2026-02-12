# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **COMMIT CHANGES** - If you modified files, you must commit. If you only updated JIRA, do not commit.
3. **JIRA IS TRUTH** - JIRA is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - PLANNER

## 1. Load Context

1. Find assigned planning tasks using `mcp__jira__searchJiraIssuesUsingJql`.
   - **JQL**: `assignee = currentUser() AND ((description is EMPTY OR description ~ "TODO") OR labels = "needs-planning") AND status != "Done" ORDER BY createdDate DESC`
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the JQL results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by JQL → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details with `mcp__jira__getJiraIssue`.

## 3. Plan & Refine

**Goal**: Turn a vague idea into a workable specification.

1.  **Analyze**: Read the Summary.
2.  **Context**: Check code or other tickets to understand what "fix X" or "implement Y" means.
3.  **Draft Description**:
    - **User Story**: "As a [User], I want [Feature], so that [Benefit]."
    - **Acceptance Criteria**: Checklist of what "Done" looks like.
    - **Technical Notes**: Files to touch, API endpoints to change.
4.  **Unknowns?**: If you genuinely don't know what to do:
    - Add label `needs-input`.
    - Add comment: "@[User] I need clarification on X."
    - STOP.

## 4. Update JIRA

1.  **Update Description**: Use `mcp__jira__editJiraIssue` to set the new rich description.
2.  **Remove Label**: If the ticket had `needs-planning`, remove it.
3.  **Transition**:
    - If ready for work: Transition to **"To Do"**.
    - If `needs-tests` (e.g. "Write tests for X"): Add label `needs-tests`.

## 5. Commit & Stop

If you modified any files (unlikely for Planner, but possible):

```
RALPH_PLANNER: Planned <JIRA-KEY>
```

If you ONLY updated JIRA:
Output `<promise>COMPLETE</promise>` immediately.

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
