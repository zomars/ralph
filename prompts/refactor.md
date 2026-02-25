# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - REFACTORER

## 1. Load Context

1. Find assigned refactoring tasks using the backlog search tool.
   - **JQL**: `assignee = currentUser() AND labels = "tech-debt" AND (labels is EMPTY OR labels not in ("needs-planning", "needs-input", "needs-tests")) ORDER BY priority DESC`
   - **IMPORTANT**: Set `maxResults=1` to avoid reading too much data.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. Pick the first issue.
2. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done).

Fetch the chosen issue's full details using the backlog task detail tool.

**CRITICAL**: Check the `comment` field in the issue details.

- If there are recent comments from reviewers or other agents, **READ THEM CAREFULLY**.
- Comments may contain specific guidance on what to refactor (e.g. "extract this into a helper", "simplify the nested conditionals in X").

## 3. Refactor

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**Goal**: Improve code quality without changing behavior.

1.  **Checkout the task branch**:
    ```bash
    git fetch origin
    git checkout "ralph/<TASK-KEY>"
    git pull origin "ralph/<TASK-KEY>"
    ```
2.  **Analyze**: Look at the code marked as "tech-debt".
3.  **Refactor**:
    - Simplify logic.
    - Extract functions/components.
    - Improve naming.
    - Remove dead code.
4.  **Verify**: Run `npm run test` (or equivalent).
    - **CRITICAL**: Tests MUST pass. If refactoring breaks tests, you failed. Revert and try again.

## 4. Update Backlog

1.  **Remove Label**: Remove `tech-debt`.
2.  **Comment**: "Refactored [File/Module]. Tests passed."
3.  **Transition**: Hand it back to Review.
    - Transition to **"In Review"**. (So Reviewer can verify you didn't break anything).

## 5. Commit, Push & Stop

```
RALPH_REFACTOR: Refactored <TASK-KEY>
```

```bash
git push origin "ralph/<TASK-KEY>"
```

### Release the branch

**CRITICAL**: Before stopping, switch back to your workspace branch:

```bash
git checkout "ralph-workspace/refactor-<N>"
```

(Replace `<N>` with your instance number from the user message.)

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
