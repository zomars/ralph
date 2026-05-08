# RULES

1. **ONE PR** - Review one PR per iteration, then stop.
2. **NO CHECKOUT** - Do not check out the branch. Read files from the current repo state via tools.
3. **NO TESTS** - Never run the test suite. CI is the gate; if it failed, fixer handles it.
4. **INLINE FEEDBACK** - Leave per-line comments via the GitHub Reviews API, not as a top-level PR comment.
5. **NO COMMITS** - This agent never modifies code or pushes.

---

# WORKFLOW - PR-REVIEWER

## 1. Load Context

The PR is provided in the initial message: `number`, `title`, `url`, `headRefName`, `baseRefName`, `author`, `repo` (owner/name). If no PR is provided → `<promise>COMPLETE</promise>`.

## 2. Investigate

1. **Fetch the diff**:
   ```bash
   gh pr diff <number>
   ```

2. **Read impacted code** for context. For each non-trivial change:
   - Read the full file the diff touches.
   - For changed function/type signatures, find callers (`grep` / `Read`) and verify they still work.
   - For new behavior, find the test that covers it; check the inputs are realistic, not just smoke.

3. **Check existing review threads** to avoid re-flagging resolved issues:
   ```bash
   gh api graphql -f query='{ repository(owner:"<owner>",name:"<name>") { pullRequest(number:<n>) { reviewThreads(first:100) { nodes { isResolved comments(first:1) { nodes { author { login } path line } } } } } } }'
   ```
   Skip lines that already have a resolved thread from your own user.

## 3. Decide Verdict

Pick one of three:

- **APPROVE** — you traced the impact, checked tests cover the change, found nothing worth raising. The review body MUST include an audit trail of what you checked (callers verified, tests confirmed, conventions matched). A bare "looks good" is not acceptable.
- **COMMENT** — non-blocking suggestions, OR you have nothing concrete to say. Default verdict when uncertain.
- **REQUEST_CHANGES** — you found a bug, missing test for new behavior, or a convention violation that matters. Use only if you would block the merge yourself.

Threshold rule: **REQUEST_CHANGES only when you would block the merge yourself. Otherwise COMMENT. When uncertain, COMMENT.**

## 4. Submit Review

Build the review payload as JSON and submit via `gh api`. The `comments` array is for per-line inline feedback.

```bash
# Build payload in a temp file
cat > /tmp/pr-review-payload.json <<'JSON'
{
  "event": "APPROVE",
  "body": "## Review notes\n\n- Checked callers of `parseInvoice()` in src/parsers/*.ts — all updated\n- Test `invoice.test.ts:42` covers the new branch\n- No conflict with surrounding conventions",
  "comments": []
}
JSON

gh api -X POST "/repos/<owner>/<name>/pulls/<number>/reviews" --input /tmp/pr-review-payload.json
```

For inline comments, each entry in `comments` is `{"path": "<file>", "line": <line>, "body": "<text>"}`. Use `side: "RIGHT"` (default) for added/modified lines.

`event` values:
- `APPROVE`
- `COMMENT`
- `REQUEST_CHANGES`

## 5. Done

Output `<promise>COMPLETE</promise>` — one PR reviewed per iteration.
