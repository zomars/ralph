# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW

## 1. Load Context

1. Find assigned tasks using the backlog search tool with query:
   `assignee = currentUser() AND status in ("To Do", "In Progress") AND (description is not EMPTY AND description !~ "TODO") AND labels not in ("needs-tests", "tech-debt", "ralph-blocked", "needs-planning", "needs-input") ORDER BY priority DESC`
   **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Any issue with label `ralph-blocked` or `ralph-failed` → fix it (remove the label after fixing)
2. Any issue with status "In Progress" → verify/continue it
3. First issue with status "To Do" / "Open" → implement it
4. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done)

Fetch the chosen issue's full details using the backlog task detail tool.

## 3. Do the Task

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**You MUST verify with evidence. Pick the appropriate method:**

| Task Type         | Verification Method                      |
| ----------------- | ---------------------------------------- |
| UI/Browser        | Playwright screenshot                    |
| API endpoint      | `curl` or test showing request/response  |
| Database schema   | Query showing table/column exists        |
| TypeScript types  | `grep` showing type definition exists    |
| Backend logic     | Unit/integration test passing            |
| Telemetry/logging | Test or code showing events are captured |
| Performance       | Benchmark or timing measurement          |

Run the dev server if needed: `npm run dev --workspace=@frendor/consolidated-app`

If the feature doesn't exist, implement it first, then verify.

Run `npm run test` before committing. If blocked by a genuine blocker (build failures, missing dependencies, failing tests), output `<promise>ABORT</promise>`.

**Ralph only works on existing issues assigned to the user.** It does NOT create new issues or subtasks.
If it can't finish in one iteration, it commits the progress made, adds a comment describing what was done and what remains, and stops. The next iteration continues where it left off.

## 4. Update Backlog

After work is complete:

1. **Add a comment** to the task:
   - **Action**: Implemented / Verified / Fixed
   - **Commit**: SHA of the commit
   - **Evidence**: Description of verification performed
   - **Files changed**: List of modified files

2. **Transition the issue**:
   - Verified with evidence → transition to "Done"
   - Implemented, needs verification → keep "In Progress"
   - Blocked/broken → add label `ralph-blocked` or `ralph-failed` + add comment explaining why

Always discover available transitions rather than hardcoding status names.

## 5. Commit & Stop

```
RALPH: <what you did> (<TASK-KEY>)

Evidence: <brief description of verification performed>
```

---

# COMPLETE

When the backlog search returns zero results for your query, output `<promise>COMPLETE</promise>` — all assigned work is done.
