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

**Goal**: Turn a vague idea into a workable specification using tracer-bullet vertical slices.

1.  **Analyze**: Read the Summary.
2.  **Context**: Explore the codebase and check other tickets to understand what "fix X" or "implement Y" means. Identify durable architectural decisions (routes, schema, key models, auth approach, third-party boundaries).
3.  **Draft vertical slices**: Break the task into **tracer bullet** phases. Each phase is a thin vertical slice that cuts through ALL integration layers end-to-end (schema → API → UI → tests), NOT a horizontal slice of one layer.
    - Each slice delivers a narrow but COMPLETE path through every layer
    - A completed slice is demoable or verifiable on its own
    - **Split aggressively** — prefer many small subtasks over few large ones. Each subtask should be completable in a single agent iteration.
    - Do NOT include specific file names, function names, or implementation details likely to change as later phases are built
    - DO include durable decisions: route paths, schema shapes, data model names
    - If the task is truly trivial (single-file fix), skip splitting
4.  **Create subtasks**: For each vertical slice, create a subtask under the parent issue using `createJiraIssue` with `parentKey` set to the current task's key. Each subtask gets:
    - **Summary**: Short, action-oriented title
    - **Description**: What to build (end-to-end behavior, not layer-by-layer) + acceptance criteria checklist
5.  **Create dependency links** using `createIssueLink` with link type "Blocks":
    - **Sequential chaining**: Each subtask is blocked by the previous one (subtask-2 blocked by subtask-1, etc.). The first subtask has no blockers.
    - **Children block parent**: Every subtask must **block** the parent issue. This prevents agents from picking up the parent while any subtask is still incomplete.
6.  **Update parent description**: Set the parent's description to an overview with:
    - **Architectural decisions**: Durable decisions that apply across all subtasks (routes, schema, models)
    - **Subtask summary**: Numbered list of subtask keys and titles for quick reference
7.  **Unknowns?**: If you genuinely don't know what to do:
    - Add label `needs-input`.
    - Add comment: "@[User] I need clarification on X."
    - STOP.

## 4. Update Backlog

1.  **Remove Label**: If the ticket had `needs-planning`, remove it.
2.  **Transition**:
    - If subtasks were created: Transition parent to **"To Do"**. The first unblocked subtask will be picked up by the implementer.
    - If no subtasks (trivial task): Transition to **"To Do"**.
    - If `needs-tests` (e.g. "Write tests for X"): Add label `needs-tests`.
    - **Never transition to "Done" or "In Review"** — only the Reviewer can mark tasks complete.

## 5. Commit & Stop

If you modified any files (unlikely for Planner, but possible):

```
RALPH_PLANNER: Planned <TASK-KEY>
```

If you ONLY updated the backlog:
Output `<promise>COMPLETE</promise>` immediately.

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
