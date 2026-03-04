# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **MUST COMMIT** - Every iteration ends with a git commit. No exceptions.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW

## 1. Load Context

1. Find assigned tasks using the backlog search tool with the query provided in the initial message.
   **IMPORTANT**: Set `maxResults` to your instance number (from the user message, e.g. "instance 2" → `maxResults=2`). Default to `maxResults=1` if no instance number is given.
2. Read last 10 RALPH commits.

## 2. Pick A SINGLE Task

From the query results (already sorted by priority):

1. If fewer results were returned than your instance number → `<promise>COMPLETE</promise>` (another instance is handling the remaining tasks)
2. Pick the **last** result returned (e.g. instance 2 picks result #2, instance 1 picks result #1)
3. Any issue with status "In Progress" → verify/continue it
4. Otherwise → implement it
5. If NO issues returned by query → `<promise>COMPLETE</promise>` (all assigned work is done)

Fetch the chosen issue's full details using the backlog task detail tool.

**CRITICAL**: Check the `comment` field in the issue details.

- If there are recent comments from reviewers or other agents, **READ THEM CAREFULLY**.
- Comments may contain rejection feedback, change requests, or new instructions that override the original description.
- If a reviewer sent the task back, address their feedback before doing anything else.

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
  # Determine base branch: check for stacked PR dependency
  BASE_BRANCH="$DEFAULT_BRANCH"
  # Look at issue links for "is blocked by" relationships
  # In the fetched issue details, check fields.issuelinks for inward links
  # where type.inward == "is blocked by"
  # For each blocker key, check if ralph/<BLOCKER-KEY> exists on remote
  # If it does → that's our base branch (stacked PR)
  # If multiple blockers have remote branches, use the first one found
  # If none have remote branches (already merged) → use $DEFAULT_BRANCH

  # Example logic (adapt to actual issuelinks data):
  for BLOCKER_KEY in <BLOCKER-KEYS-FROM-ISSUELINKS>; do
    if git ls-remote --heads origin "ralph/$BLOCKER_KEY" | grep -q .; then
      BASE_BRANCH="ralph/$BLOCKER_KEY"
      break
    fi
  done

  git checkout -b "ralph/<TASK-KEY>" "origin/$BASE_BRANCH"
fi
```

**Stacked PRs**: If this task is blocked by another task that has an active `ralph/<BLOCKER-KEY>` branch, we branch from that instead of `$DEFAULT_BRANCH`. This enables parallel work — the dependent PR targets the blocker's branch, and after the blocker merges, the reviewer rebases the child.

All work for this task happens on the `ralph/<TASK-KEY>` branch.

## 3. Do the Task

**Before starting work**, transition the issue to "In Progress":

1. Get available transitions for the task
2. Transition to "In Progress"

**Then implement the task. Follow these steps:**

1. **Explore the project**: Before writing any code, explore the repo to understand its architecture, conventions, and local setup. Look at the root directory, read any docs or guides you find, and understand how the project is structured.
2. **Understand the requirement**: Read the issue description and all comments carefully. Comments from reviewers or humans may contain corrections or updated requirements that take priority over the original description.
3. **Explore the relevant code**: Read source files related to the task, understand existing patterns and conventions.
4. **Plan your changes**: Identify which files need to be created or modified. Keep changes minimal and focused.
5. **Write the code**: Implement the feature, fix, or change described in the issue. Follow existing code style and patterns.
6. **Verify with evidence**: Confirm your implementation works using the appropriate method:

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

7. **Run tests**: Run `npm run test` before committing. If blocked by a genuine blocker (build failures, missing dependencies, failing tests), output `<promise>ABORT</promise>`.

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

After committing, push and open (or update) a PR:

```bash
git push -u origin "ralph/<TASK-KEY>"
# Create PR if one doesn't exist yet
# Use BASE_BRANCH from branch setup (blocker branch for stacked PRs, or DEFAULT_BRANCH)
if ! gh pr list --head "ralph/<TASK-KEY>" --json number --jq '.[0].number' 2>/dev/null | grep -q .; then
  gh pr create --draft --base "$BASE_BRANCH" --head "ralph/<TASK-KEY>" --title "<TASK-KEY>: <summary>" --body "Implements <TASK-KEY>"
fi
```

**If transitioning to "In Review"** (verified with evidence), undraft the PR:
```bash
gh pr ready "ralph/<TASK-KEY>"
```

Do NOT undraft if keeping status at "In Progress" (partial progress).

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
