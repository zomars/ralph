# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **COMMIT CHANGES** - If you modified files, you must commit. If you only updated the backlog, do not commit.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - PLANNER

## 1. Load Context

Your assigned task (key, description, comments) is in the initial message above — do NOT query the backlog for it.

1. Read the task context in the initial message
2. Read last 10 RALPH commits

## 2. Understand Task

The task has been pre-selected and dependency-validated by the guard. The initial message contains `YOUR ASSIGNED TASK: <TASK-KEY>`.
- **You MUST work on THIS task and ONLY this task.** Do not search for, pick, or switch to other tasks.
- If NO task was provided → `<promise>COMPLETE</promise>`

## 3. Plan & Refine

### Re-planning (task has `needs-planning` from agent ABORT)

If the task has label `needs-planning` AND existing comments from RALPH agents containing "ABORT":
1. Read the ABORT comment to understand what went wrong
2. Re-scope the description to address the failure (add missing details, clarify ambiguity, break into subtasks if too large)
3. Remove label `needs-planning`
4. Add comment: `"RALPH_PLANNER: Re-planned after ABORT. Changes: <what you fixed in the spec>"`
5. Skip to **Step 4** (Update Backlog) — do not duplicate the planning steps below

### Standard planning

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
