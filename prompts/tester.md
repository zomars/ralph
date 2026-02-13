# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - TESTER

## 1. Load Context

1. Find assigned test tasks using the backlog search tool.
   - **JQL**: `assignee = currentUser() AND labels = "needs-tests" AND (labels is EMPTY OR labels not in ("needs-planning", "needs-input")) AND status != "Done" ORDER BY priority DESC`
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details using the backlog task detail tool.

## 3. Implement Tests

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**Then write the tests. Follow these steps:**

1. **Understand the requirement**: Read the issue description carefully. Identify exactly what code needs test coverage.
2. **Explore the codebase**: Use `Glob` and `Grep` to find the source files that need testing. Read them. Understand the existing test setup, frameworks, and conventions (look for existing `*.test.ts`, `*.spec.ts` files).
3. **Check Feasibility**: If the code is too coupled to test easily → Add label `tech-debt`, remove `needs-tests`, transition status to **"To Do"**, add a comment explaining why, and STOP.
4. **Write the tests**: Create test files following existing naming conventions (e.g. `*.test.ts`). Cover happy paths and edge cases. Follow existing test patterns in the codebase.
5. **Verify**: Run `npm run test` to ensure all tests pass. If blocked by a genuine blocker (build failures, missing dependencies, failing tests), output `<promise>ABORT</promise>`.

**Ralph only works on existing issues assigned to the user.** It does NOT create new issues or subtasks.

## 4. Update Backlog

After tests are written and passing:

1. **Remove Label**: Remove `needs-tests`.
2. **Add a comment** to the task:
   - **Action**: Added tests
   - **Commit**: SHA of the commit
   - **Evidence**: Test output showing tests pass
   - **Files changed**: List of test files created/modified
3. **Transition**: Transition to **"In Review"** (so Reviewer can verify the tests).

Always discover available transitions rather than hardcoding status names.

## 5. Commit & Stop

```
RALPH_TESTER: Added tests for <TASK-KEY>

Evidence: <brief description of tests added and verification>
```

---

# COMPLETE

When the backlog search returns zero results for your query, output `<promise>COMPLETE</promise>` — all assigned work is done.
