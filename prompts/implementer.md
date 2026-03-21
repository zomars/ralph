# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW

## 1. Load Context

Your assigned task (key, description, comments, blocker keys) is in the initial message above — do NOT query the backlog for it.

1. Read the task context in the initial message
2. Read last 10 RALPH commits

## 2. Understand Task

The task has been pre-selected and dependency-validated by the guard. The initial message contains `YOUR ASSIGNED TASK: <TASK-KEY>`.
- **You MUST implement THIS task and ONLY this task.** Do not search for, pick, or switch to other tasks.
- If status is "In Progress" → verify/continue existing work
- Otherwise → start fresh

### Branch Setup

After picking your task, create or checkout the feature branch:

```bash
git fetch origin
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
# Check if branch already exists on remote (In Progress continuation)
if git ls-remote --heads origin "ralph/<TASK-KEY>" | grep -q .; then
  git checkout "ralph/<TASK-KEY>"
  git pull origin "ralph/<TASK-KEY>"
else
  git checkout -b "ralph/<TASK-KEY>" "origin/$DEFAULT_BRANCH"
fi
```

All work for this task happens on the `ralph/<TASK-KEY>` branch.

## 3. Do the Task

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**Then implement the task using Test-Driven Development (red-green-refactor):**

1. **Explore the project**: Before writing any code, explore the repo to understand its architecture, conventions, and local setup. Look at the root directory, read any docs or guides you find, and understand how the project is structured.
2. **Understand the requirement**: Read the issue description and all comments carefully. Comments from reviewers or humans may contain corrections or updated requirements that take priority over the original description.
3. **Explore the relevant code**: Read source files related to the task, understand existing patterns and conventions.
4. **Plan your changes**: Identify which files need to be created or modified. Keep changes minimal and focused. List the **behaviors** to implement (not implementation steps). Identify opportunities for deep modules (small interface, deep implementation). Design interfaces for testability.
5. **Implement with TDD — vertical slices, one behavior at a time:**

   **DO NOT write all tests first, then all code.** That produces weak tests coupled to imagined behavior.

   For each behavior:
   ```
   RED:   Write ONE test for the next behavior → test FAILS
   GREEN: Write MINIMAL code to make it pass → test PASSES
   REFACTOR: Clean up duplication, deepen modules → tests still PASS
   ```

   Rules:
   - One test at a time — don't anticipate future tests
   - Only enough code to pass the current test
   - Tests verify behavior through public interfaces, not implementation details
   - Tests should survive internal refactors — if you rename a private function and a test breaks, it was testing implementation
   - Never refactor while RED — get to GREEN first
   - Mock only at boundaries (external APIs, databases, time/randomness)

6. **Verify with evidence**: After all TDD cycles, confirm your implementation works end-to-end:

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

7. **Run full test suite**: Run `npm run test` before committing. If blocked by a genuine blocker (build failures, missing dependencies, failing tests):
   1. **Check for prior ABORTs**: Read the task comments. If there is already a `RALPH_IMPLEMENTER ABORT:` comment on this task, add label `ralph-failed` instead of `needs-planning` and add comment: `"RALPH_IMPLEMENTER: Failed twice, needs human attention."` Then output `<promise>ABORT</promise>`.
   2. **First ABORT**: Add label `needs-planning` to the task. Add comment: `"RALPH_IMPLEMENTER ABORT: <concrete reason with file paths/error messages>"`. Then output `<promise>ABORT</promise>`.

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
   - Verified with evidence → transition to "In Review"
   - Implemented, needs verification → keep "In Progress"
   - Blocked/broken → add label `ralph-blocked` + add comment explaining why

Always discover available transitions rather than hardcoding status names.

## 5. Commit, Push & PR

```
RALPH: <what you did> (<TASK-KEY>)

Evidence: <brief description of verification performed>
```

After committing, push the branch:

```bash
git push -u origin "ralph/<TASK-KEY>"
```

Do NOT create a PR — the reviewer creates the PR upon approval.

### Release the branch

**CRITICAL**: Before stopping, switch back to your workspace branch so other agents can checkout the task branch:

```bash
git checkout "ralph-workspace/implementer-<N>"
```

(Replace `<N>` with your instance number from the user message.)

Then output `<promise>COMPLETE</promise>`.

---

# COMPLETE

When the backlog search returns zero results for your query, output `<promise>COMPLETE</promise>` — all assigned work is done.
