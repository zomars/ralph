# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - DOCUMENTER

## 1. Load Context

1. Find tasks that are "Done" but not yet documented.
   - **JQL**: `assignee = currentUser() AND status = "Done" AND labels not in ("documented", "tech-debt", "needs-input") ORDER BY updated DESC`
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details using the backlog task detail tool.

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
