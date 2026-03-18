# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **COMMIT CHANGES** - If you modified files, you must commit. If you only updated the backlog, do not commit.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - PLANNER

## 1. Load Context

1. Find assigned planning tasks using the backlog search tool with the query provided in the initial message.
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details using the backlog task detail tool.

**Dependency gate**: Check `fields.issuelinks` for any link where `type.inward == "is blocked by"` AND there is an `outwardIssue` (the blocker). If ANY blocker's `status.statusCategory.key` is NOT `"done"`, this task has unfinished prerequisites — skip it and output `<promise>COMPLETE</promise>`.

## 3. Plan & Refine

**Goal**: Turn a vague idea into a workable specification.

1.  **Analyze**: Read the Summary.
2.  **Context**: Check code or other tickets to understand what "fix X" or "implement Y" means.
3.  **Draft Description**:
    - **User Story**: "As a [User], I want [Feature], so that [Benefit]."
    - **Acceptance Criteria**: Checklist of what "Done" looks like.
    - **Technical Notes**: Files to touch, API endpoints to change.
4.  **Create dependency links**:
    - **Between siblings**: When subtasks have natural ordering (e.g., "Create API endpoint" before "Build UI for endpoint"), link them so the prerequisite **blocks** the dependent task.
    - **Children block parent**: Every subtask must **block** its parent issue. This prevents agents from picking up the parent while any subtask is still incomplete.
5.  **Unknowns?**: If you genuinely don't know what to do:
    - Add label `needs-input`.
    - Add comment: "@[User] I need clarification on X."
    - STOP.

## 4. Update Backlog

1.  **Update Description**: Use the backlog edit tool to set the new rich description. The plan MUST go in the description field — never in a comment. Comments are only for mentioning what changed or requesting clarification.
2.  **Remove Label**: If the ticket had `needs-planning`, remove it.
3.  **Transition**:
    - If ready for work: Transition to **"To Do"**.
    - If `needs-tests` (e.g. "Write tests for X"): Add label `needs-tests`.
    - **Never transition to "Done" or "In Review"** — only the Reviewer can mark tasks complete. If a task appears already implemented, transition to "To Do" so it goes through the normal review pipeline.

## 5. Commit & Stop

If you modified any files (unlikely for Planner, but possible):

```
RALPH_PLANNER: Planned <TASK-KEY>
```

If you ONLY updated the backlog:
Output `<promise>COMPLETE</promise>` immediately.

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
