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

4. After fixing, proceed to Step 3 — always check for review feedback too.

## 3. Read & Address Feedback

1. **Read all review comments:**
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/comments --jq '.[] | {id, path, line, body, user: .user.login, in_reply_to_id}'
   ```

2. **Read review threads with resolution status:**
   ```bash
   gh api graphql -f query='
   {
     repository(owner: "{owner}", name: "{repo}") {
       pullRequest(number: {number}) {
         reviewThreads(first: 50) {
           nodes {
             id
             isResolved
             line
             path
             comments(first: 10) {
               nodes {
                 id
                 body
                 author { login }
               }
             }
           }
         }
       }
     }
   }
   '
   ```

3. **Read PR-level reviews** (for top-level review body text):
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[] | {id, state, body, user: .user.login}'
   ```

4. Filter to only **unresolved** threads and unanswered comments. Ignore threads already resolved or that you authored.

5. If there is no unresolved feedback → skip to Step 4.

6. For each unresolved review comment/thread:
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

For each piece of feedback you addressed in Step 3:

1. **Reply to the comment** explaining what you changed:
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies -f body="Fixed — <brief explanation of what was changed>"
   ```

2. **Resolve the thread** via GraphQL:
   ```bash
   gh api graphql -f query='
   mutation {
     resolveReviewThread(input: {threadId: "<thread_id>"}) {
       thread { isResolved }
     }
   }
   '
   ```

If a comment is unclear or you cannot address it, reply explaining why instead of silently skipping it.

## 6. Dismiss Reviews

**Always dismiss CHANGES_REQUESTED reviews before completing** — this clears the review state and prevents the fixer from re-picking the PR.

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[] | select(.state == "CHANGES_REQUESTED") | .id' | while read -r rid; do
  gh api -X PUT "repos/{owner}/{repo}/pulls/{number}/reviews/${rid}/dismissals" -f message="All feedback addressed"
done
```

If dismissal fails (e.g. branch protection prevents it), add label `blocked` and leave a comment explaining why.

## 7. Done

Output `<promise>COMPLETE</promise>` — one PR has been fixed per iteration.
