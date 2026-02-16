# RULES

1. **ONE PR** - Fix one PR per iteration, then stop.
2. **MUST COMMIT & PUSH** - Every iteration ends with a git commit and push. No exceptions.
3. **REPLY TO REVIEWERS** - After pushing fixes, reply to every addressed comment and resolve threads.
4. **NO SCOPE CREEP** - Only fix what reviewers asked for. Do not refactor, improve, or "clean up" unrelated code.

---

# WORKFLOW - FIXER

## 1. Find PRs Needing Fixes

Run BOTH of these searches to find PRs with unresolved feedback:

**Search A — Formal "changes requested":**
```bash
gh pr list --author "@me" --search "review:changes_requested" --json number,title,url,headRefName
```

**Search B — PRs with unresolved review threads (catches inline comments without formal rejection):**
```bash
gh api graphql -f query='
{
  search(query: "is:pr is:open author:@me", type: ISSUE, first: 20) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        headRefName
        reviewThreads(first: 50) {
          nodes {
            isResolved
            comments(first: 1) {
              nodes {
                body
                author { login }
              }
            }
          }
        }
      }
    }
  }
}
' --jq '.data.search.nodes[] | select(.reviewThreads.nodes | map(select(.isResolved == false)) | length > 0) | {number, title, url, headRefName}'
```

Combine results, deduplicate by PR number.

## 2. Pick A SINGLE PR

From the combined results:

1. If no PRs need attention → `<promise>COMPLETE</promise>`
2. **IMPORTANT**: Set your instance number from the user message (e.g. "instance 2"). If fewer PRs exist than your instance number → `<promise>COMPLETE</promise>`
3. Pick the PR corresponding to your instance number (instance 1 → first PR, instance 2 → second PR, etc.)

## 3. Checkout & Read Feedback

1. **Checkout the branch:**
   ```bash
   git fetch origin
   git checkout <headRefName>
   git pull origin <headRefName>
   ```

2. **Read all review comments:**
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/comments --jq '.[] | {id, path, line, body, user: .user.login, in_reply_to_id}'
   ```

3. **Read review threads with resolution status:**
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

4. **Read PR-level reviews** (for top-level review body text):
   ```bash
   gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[] | {id, state, body, user: .user.login}'
   ```

5. Filter to only **unresolved** threads and unanswered comments. Ignore threads already resolved or that you authored.

## 4. Address Each Piece of Feedback

For each unresolved review comment/thread:

1. **Read** the file at the mentioned path and line
2. **Understand** what the reviewer is asking for
3. **Make the change** — edit the file to address the feedback
4. **Verify** the change makes sense in context (read surrounding code)

Work through ALL unresolved feedback before moving to the next step.

## 5. Test, Commit & Push

1. **Run tests:**
   ```bash
   npm run test
   ```
   If tests fail due to your changes, fix them. If blocked by a genuine blocker unrelated to your changes, output `<promise>ABORT</promise>`.

2. **Commit:**
   ```
   RALPH_FIXER: Address review feedback (PR #<number>)

   - <brief summary of each change made>
   ```

3. **Push:**
   ```bash
   git push origin <headRefName>
   ```

## 6. Reply & Resolve

For each piece of feedback you addressed:

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

## 7. Done

Output `<promise>COMPLETE</promise>` — one PR has been fixed per iteration.
