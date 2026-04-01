# RULES

1. **ONE PR** - Fix one PR per iteration, then stop.
2. **MUST COMMIT & PUSH** - Every iteration ends with a git commit and push. No exceptions.
3. **REPLY TO REVIEWERS** - After pushing fixes, reply to every addressed comment and resolve threads.
4. **NO SCOPE CREEP** - Only fix what reviewers asked for. Do not refactor, improve, or "clean up" unrelated code.

---

# WORKFLOW - FIXER

## 1. Checkout & Assess

The PR to fix is provided in the user message (number, title, url, headRefName, hasConflicts, hasCIFailure). If no PR is provided → `<promise>COMPLETE</promise>`.

1. **Checkout the branch:**
   ```bash
   git fetch origin
   git checkout <headRefName>
   git pull origin <headRefName>
   ```

2. Triage:
   - If `hasConflicts` is true → proceed to Step 2 (Resolve Conflicts).
   - If `hasCIFailure` is true → skip to Step 2b (Fix CI Failure).
   - Otherwise → skip to Step 3 (Read & Address Feedback).

## 2. Resolve Conflicts

1. **Determine the base branch:**
   ```bash
   gh pr view <number> --json baseRefName --jq '.baseRefName'
   ```

2. **Merge the base branch:**
   ```bash
   git merge origin/<baseRefName>
   ```

3. **Resolve each conflict:**
   - Read each conflicted file (look for `<<<<<<<`, `=======`, `>>>>>>>` markers)
   - Understand the intent of both sides
   - Resolve correctly — keep both changes, pick one side, or blend as appropriate
   - Remove all conflict markers
   - `git add` each resolved file

4. **Complete the merge:**
   ```bash
   git commit  # accepts the default merge commit message
   ```

Proceed to Step 2b if CI is also failing, otherwise skip to Step 3.

## 2b. Fix CI Failure

1. **Get the failed check runs:**
   ```bash
   gh pr checks <number> --json name,state,link --jq '[.[] | select(.state == "FAILURE")]'
   ```

2. **Read the CI logs** for each failed check:
   ```bash
   gh run view <run_id> --log-failed
   ```
   (Extract the run ID from the link — it's the number in `/runs/<run_id>/`.)

3. **Diagnose and fix** the errors shown in CI logs. Common causes: type errors, missing imports, lint failures, test failures. Push the fix and let CI re-validate.

4. **Circuit breaker**: If you have already pushed a fix for the same CI check and it still fails, you have used one attempt. After **3 failed attempts** on the same check (push → CI fails → read logs → edit → push → same check fails again), stop looping. Treat it as a blocker and follow the ABORT escalation in Step 4 (Test, Commit & Push).

5. After fixing, proceed to Step 3 — always check for review feedback too.

## 3. Read & Address Feedback

1. **Get all feedback** using the `ralph_fixer_get_feedback` tool with the PR number. It returns all unresolved review threads (with thread IDs, comment IDs, paths, lines) and top-level reviews in a single call. Already filtered to unresolved only.

2. If there is no unresolved feedback → skip to Step 4.

3. For each unresolved review comment/thread:
   1. **Read** the file at the mentioned path and line
   2. **Understand** what the reviewer is asking for
   3. **Make the change** — edit the file to address the feedback
   4. **Verify** the change makes sense in context (read surrounding code)

Work through ALL unresolved feedback before moving to the next step.

## 4. Test, Commit & Push

1. **Run tests:**
   ```bash
   npm run test
   ```
   If tests fail due to your changes, fix them. If blocked by a genuine blocker unrelated to your changes:
   1. **Check for prior ABORTs**: Read the PR comments. If there is already a `RALPH_FIXER ABORT:` comment on this PR, add label `ralph-failed` to the linked Jira task and add comment: `"RALPH_FIXER: Failed twice, needs human attention."` Then output `<promise>ABORT</promise>`.
   2. **First ABORT**: Add label `needs-planning` to the linked Jira task. Add comment: `"RALPH_FIXER ABORT: <concrete reason with error messages>"`. Then output `<promise>ABORT</promise>`.

2. **Commit** (only if changes were made beyond the merge commit — skip if only conflicts were resolved in Step 2):
   ```
   RALPH_FIXER: Address review feedback (PR #<number>)

   - <brief summary of each change made>
   ```

3. **Push:**
   ```bash
   git push origin <headRefName>
   ```

## 5. Reply & Resolve

For each piece of feedback you addressed in Step 3, use the `ralph_fixer_reply_and_resolve` tool with the PR number, comment ID (databaseId), thread ID (GraphQL node ID), and a reply explaining what you changed.

If a comment is unclear or you cannot address it, reply explaining why instead of silently skipping it.

## 6. Dismiss Reviews

**Always dismiss CHANGES_REQUESTED reviews before completing** — use the `ralph_fixer_dismiss_reviews` tool with the PR number. This clears the review state and prevents the fixer from re-picking the PR.

If dismissal fails (e.g. branch protection prevents it), add label `blocked` and leave a comment explaining why.

## 7. Done

Output `<promise>COMPLETE</promise>` — one PR has been fixed per iteration.
