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

**Goal**: Turn a vague idea into a workable specification using tracer-bullet vertical slices. Default to **no split**. Split only when necessary.

1.  **Analyze**: Read the Summary.
2.  **Context**: Explore the codebase and check other tickets to understand what "fix X" or "implement Y" means. Identify durable architectural decisions (routes, schema, key models, auth approach, third-party boundaries).
3.  **Decide whether to split**. Ask: *can one implementer iteration ship this end-to-end?* If yes → **no subtasks**, skip to Step 6. Only split when at least one holds:
    - Task spans multiple independent user-visible behaviors.
    - Task crosses a hard architectural seam (new service; schema migration + UI consumer).
    - Task is too large for one implementer iteration AND cannot be tightened.
4.  **Draft vertical slices** (only if Step 3 says split):
    - Each slice is a thin vertical slice cutting through ALL integration layers end-to-end (schema → API → UI → tests), NOT a horizontal slice of one layer. A slice may span multiple files/layers — that is expected.
    - Each slice is demoable / verifiable on its own and independently shippable.
    - **Prefer fewer thick slices over many thin ones.** Do not split aggressively.
    - For each slice record: **Title**, **Type (HITL/AFK)**, **Blocked by** (real blockers only), **Acceptance criteria** as a checklist.
    - Prefer **AFK** (no human gate). Mark a slice **HITL** only when it requires human input: architecture decision, design review, credentials/secrets.
    - Do NOT include specific file names, function names, or implementation details likely to change as later phases are built. DO include durable decisions: route paths, schema shapes, data model names.
5.  **Create subtasks** using `createJiraIssue` with `parentKey` set to the current task's key. Subtask description template:

    ```
    ## What to build
    <end-to-end behavior, not layer-by-layer>

    ## Acceptance criteria
    - [ ] ...
    - [ ] ...

    ## Blocked by
    - <KEY> (or "None - can start immediately")

    ## Type
    AFK | HITL
    ```

    For HITL subtasks: also add label `needs-input` at creation.

    Then create dependency links via `createIssueLink` with link type "Blocks":
    - **Direction**: `inwardIssue` is the **blocker** (the one that must finish first), `outwardIssue` is the **blocked** issue. Read it as: "`outwardIssue` is blocked by `inwardIssue`." If A must ship before B, call with `inwardIssue=A, outwardIssue=B`. Verify after creation by re-reading the parent — `inwardIssue` entries on the parent are its blockers.
    - **Reserve `Blocks` for real dependencies** (slice B reads schema/route created by slice A) so independent slices ship in parallel.
    - **Leave siblings unlinked by default** — chain them only when one genuinely consumes another's output, because chaining serializes work that could run in parallel.
    - **Skip child-blocks-parent links for real Jira sub-tasks** (created with `parentKey`). `routing.json` sets `skip_with_open_subtasks: true`, so the parent is already gated and an extra `Blocks` link is redundant.
    - **Add child-blocks-parent links when children are peer Tasks** (separate issues with no `parentKey`, related only by `Blocks`). The sub-task gate is silent here, so `Blocks` is the only mechanism that keeps the parent out of the implementer queue until the children finish.
    - **Link a HITL blocker to its AFK consumer** when an AFK subtask depends on HITL work, so the AFK task waits for human resolution.
6.  **Update parent description**: Set the parent's description to an overview with:
    - **Architectural decisions**: Durable decisions that apply across all subtasks (routes, schema, models)
    - **Subtask summary**: Numbered list of subtask keys and titles for quick reference (omit if no subtasks created)
7.  **Unknowns?**: If you genuinely don't know what to do at the parent level:
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
