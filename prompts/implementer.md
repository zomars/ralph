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

**Then implement the task:**

1. **Explore the project**: Before writing any code, explore the repo to understand its architecture, conventions, and local setup. Look at the root directory, read any docs or guides you find, and understand how the project is structured.
2. **Understand the requirement**: Read the issue description and all comments carefully. Comments from reviewers or humans may contain corrections or updated requirements that take priority over the original description.
3. **Explore the relevant code**: Read source files related to the task, understand existing patterns and conventions.
4. **Plan your changes**: Identify which files need to be created or modified. Keep changes minimal and focused.
   - List the **behaviors** to implement (not implementation steps)
   - Identify opportunities for deep modules (small interface, deep implementation)
   - Decide on interfaces before writing implementation

5. **Implement in vertical slices** — one behavior at a time, not all-at-once.

   **Tests — only when warranted:**
   - Task explicitly requires writing or modifying tests
   - Pure backend logic with no UI surface (services, utils, API handlers)
   - Complex business rules where type-checking alone is insufficient

   When you do write tests: test behavior through public interfaces, not implementation details. One test run to confirm green — no red-green-refactor ceremony.

   ### Design Principles

   - **Deep modules**: Small interface, rich implementation. Avoid shallow pass-throughs.
   - **Inject dependencies**: Accept collaborators as params, don't instantiate them internally.
   - **Return results over side effects**: Prefer `fn(input): Output` over `fn(input): void` that mutates.
   - **Minimize surface area**: Fewer exported functions = less to maintain and test.
   - **Mock only at boundaries**: External APIs, time, randomness. Never mock your own modules.

   ### Implementation Checklist

   ```
   [ ] No speculative features — only what the task requires
   [ ] Follows existing project conventions and patterns
   [ ] Changes are minimal and focused on the task
   ```

6. **Verify with evidence**: Confirm your implementation works. Type-checks and tests run on pre-push hooks — don't run them manually.

| Task Type         | Verification Method                      |
| ----------------- | ---------------------------------------- |
| UI/Browser        | Playwright screenshot                    |
| API endpoint      | `curl` or test showing request/response  |
| Database schema   | Query showing table/column exists        |
| TypeScript types  | `grep` showing type definition exists    |
| Backend logic     | Related tests passing (only if warranted)|
| Telemetry/logging | Code showing events are captured         |
| Performance       | Benchmark or timing measurement          |

Run the dev server if needed (check the worktree setup output for the correct command).

7. **Commit your changes** — CI and git hooks validate builds and tests. If a pre-commit hook rejects the commit, fix the issue and retry.

**Subtask awareness**: If the task has a parent (shown in KB as `Parent: PROJ-123`), read the parent's description for architectural decisions and overall context before starting work. The parent description contains the high-level plan; your subtask is one vertical slice of it.

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

After committing, push the branch and create a draft PR using the `ralph_implementer_create_pr` tool:

```bash
git push -u origin "ralph/<TASK-KEY>"
```

Then call `ralph_implementer_create_pr` with your task key. The tool automatically:
- Creates the PR as **draft** (enforced — cannot be overridden)
- Detects the correct base branch from Jira blocker links (stacked PRs)
- Is idempotent (returns existing PR if one exists)

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
