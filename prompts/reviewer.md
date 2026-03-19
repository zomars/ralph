# RULES

1. **ONE TASK** - Do one task, commit, stop.
2. **COMMIT CHANGES** - If you modified files, you must commit. If you only updated the backlog, do not commit.
3. **BACKLOG IS TRUTH** - The backlog is the source of truth for task status. Never modify local files for tracking.
4. **NO SKIPPING** - Every task must be verified with evidence.

---

# WORKFLOW - REVIEWER

## 1. Load Context

Your assigned task (key, description, comments) is in the initial message above — do NOT query the backlog for it.

1. Read the task context in the initial message
2. Read last 10 RALPH commits

## 2. Understand Task

The task has been pre-selected and dependency-validated by the guard. The initial message contains `YOUR ASSIGNED TASK: <TASK-KEY>`.
- **You MUST work on THIS task and ONLY this task.** Do not search for, pick, or switch to other tasks.
- If NO task was provided → `<promise>COMPLETE</promise>`

## 3. Review the Task

**Goal**: Verify the implementation is correct, clean, and has been properly tested with evidence.

1.  **Explore the project**: Before reviewing, explore the repo to understand its architecture and conventions. Look at the root directory, read any docs or guides you find.
2.  **Checkout the task branch**:
    ```bash
    git fetch origin
    git checkout "ralph/<TASK-KEY>"
    git pull origin "ralph/<TASK-KEY>"
    ```
3.  **Run Tests**: Execute `npm run test` (or equivalent).
    - If tests FAIL: Reject immediately.
4.  **Analyze Code**: Read the changes.
    - **Logic Check**: Is the implementation correct based on the ticket description?
    - **Code Quality**: Is the code clean? Any obvious bad patterns?
    - **Test Coverage**: Are there new tests for the new feature?
5.  **Verify Testing Evidence**: Read the issue comments looking for a **test report from the Tester agent**.
    - A valid test report MUST include: numbered test steps, screenshots as evidence, and a PASS/FAIL result.
    - **Evaluate evidence quality against the PRD**: Compare the test report against the ticket's acceptance criteria. Each acceptance criterion should have corresponding evidence (screenshot, API response, or measurable outcome). Generic "it works" screenshots without clear mapping to acceptance criteria are insufficient.
    - If no test report exists, or the report lacks screenshots/evidence, or the evidence doesn't adequately cover the acceptance criteria — route to Path B.

## 4. Decide & Transition

Based on your analysis, choose ONE path:

### Path A: REJECT (Logic/Tests Failed)

- **Action**: Comment on the task explaining _exactly_ what failed.
- **Re-draft PR**:
  ```bash
  gh pr ready --undo "ralph/<TASK-KEY>"
  ```
- **Transition**: Move status back to **"In Progress"**.
- **Jira Label**: (Optional) If it was a build error, read current labels from the issue, append `ralph-failed`, and update via `editJiraIssue` with the full label list as `{"labels": [{"name": "label1"}, {"name": "label2"}]}`.

### Path B: NEEDS TESTING (No Evidence of Browser Testing)

- **Action**: Comment with **specific testing guidance** for the Tester agent. The comment MUST include:
  1. Which acceptance criteria lack evidence
  2. What constitutes acceptable evidence for each (e.g. "Screenshot of upload returning 201 with file_path in response", "Screenshot showing radon alert triggered for reading > 4.0 pCi/L", "API response showing structured_data matches the extraction schema")
  3. Any edge cases the tester should cover based on the PRD
- **Re-draft PR**:
  ```bash
  gh pr ready --undo "ralph/<TASK-KEY>"
  ```
- **Jira Label**: Read current labels from the issue, append `needs-tests`, and update via `editJiraIssue` with the full label list as `{"labels": [{"name": "label1"}, {"name": "needs-tests"}]}`.
- **Transition**: Move status to **"To Do"**. (This hands off to the Tester Agent).

### Path C: APPROVE (Good to Go)

- **Precondition**: Tests pass, code is clean, AND a test report with screenshots exists that adequately covers the ticket's acceptance criteria.
- **Action**: Comment "Verified. Tests passed. Browser testing evidence confirmed. Code looks good."
- **Jira Label**: Read current labels from the issue, append `ready-to-merge`, and update via `editJiraIssue` with the full label list as `{"labels": [{"name": "label1"}, {"name": "ready-to-merge"}]}`. This prevents the reviewer from re-picking this task.
- **PR Label for merge**:
  ```bash
  gh label create ready-to-merge --description "Reviewer-approved, safe to merge" --color 0E8A16 --force
  gh pr edit "ralph/<TASK-KEY>" --add-label "ready-to-merge"
  ```
- **Transition**: Keep status at **"In Review"** — the merger will move it to "Done" after merging.

## 5. Commit & Stop

If you made any changes (e.g. minor fixes, adding labels via script), commit and push:

```
RALPH_REVIEWER: Reviewed <TASK-KEY> -> <DECISION>
```

```bash
git push origin "ralph/<TASK-KEY>"
```

### Release the branch

**CRITICAL**: Before stopping, switch back to your workspace branch:

```bash
git checkout "ralph-workspace/reviewer-<N>"
```

(Replace `<N>` with your instance number from the user message.)

If you ONLY updated the backlog (no code changes), release the branch immediately.

Output `<promise>COMPLETE</promise>` when the loop finishes one task.
