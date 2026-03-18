# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - DOCUMENTER

## 1. Load Context

Your assigned task (key, description, comments) is in the initial message above — do NOT query the backlog for it.

1. Read the task context in the initial message
2. Read last 10 RALPH commits

## 2. Understand Task

The task has been pre-selected and dependency-validated by the guard. The initial message contains `YOUR ASSIGNED TASK: <TASK-KEY>`.
- **You MUST work on THIS task and ONLY this task.** Do not search for, pick, or switch to other tasks.
- If NO task was provided → `<promise>COMPLETE</promise>`

## 3. Document

**Goal**: Ensure code and docs are in sync.

1.  **Analyze**: What changed in this ticket?
2.  **Scan Docs**: Check `README.md`, `/docs`, or code comments.
3.  **Update**:
    - **New Feature?** Add to `README.md` features list.
    - **New Env Var?** Update `.env.example` (if safe) or `README`.
    - **New API?** Update API docs.
    - **Complex Logic?** Add JSDoc/Comments if missing.
4.  **Verify**: Ensure markdown is valid.

## 4. Update Backlog

1.  **Add Label**: Add `documented`.
2.  **Comment**: "Updated documentation for [Feature]."
3.  **Status**: Keep as **"Done"**.

## 5. Commit & Stop

```
RALPH_DOCS: Updated docs for <TASK-KEY>
```

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
