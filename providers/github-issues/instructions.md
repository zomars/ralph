# BACKLOG PROVIDER: GITHUB ISSUES

You are connected to GitHub Issues as the backlog provider. Use the `gh` CLI via Bash tool for all operations. No MCP tools are needed.

## Tools

All interactions use the `gh` CLI. Run commands via the Bash tool.

- **Search issues**: `gh issue list --repo $GITHUB_REPO --assignee @me --state open --search '<search query>' --json number,title,labels,body --limit 100`
- **Get issue details**: `gh issue view <number> --repo $GITHUB_REPO --json number,title,body,labels,assignees,state,comments`
- **Edit issue (labels)**: `gh issue edit <number> --repo $GITHUB_REPO --add-label "label1" --remove-label "label2"`
- **Change status**: Remove old status label and add new one:
  ```bash
  gh issue edit <number> --repo $GITHUB_REPO --remove-label "status:to-do" --add-label "status:in-progress"
  ```
- **Add comment**: `gh issue comment <number> --repo $GITHUB_REPO --body "your comment here"`
- **Create issue**: `gh issue create --repo $GITHUB_REPO --title "Title" --body "Description" --label "status:to-do" --assignee @me`

## Status Names

Statuses are implemented as labels with a `status:` prefix.

| Generic         | GitHub Label       |
| --------------- | ------------------ |
| Open/New        | `status:to-do`     |
| Working         | `status:in-progress` |
| Review          | `status:in-review` |
| Complete        | `status:done`      |

**Changing status**: Always remove the old status label and add the new one in a single `gh issue edit` call:
```bash
gh issue edit 123 --repo $GITHUB_REPO --remove-label "status:to-do" --add-label "status:in-progress"
```

## Task Key Format

GitHub issue keys use the `#123` format. Use `#<number>` as `<TASK-KEY>` in commit messages.

## Query Language

GitHub Issues uses search syntax. The DSL queries in prompt files describe filter criteria. To search, construct a `--search` string for `gh issue list`.

Example — find open issues assigned to me with `status:to-do` label, excluding `needs-input`:
```bash
gh issue list --repo $GITHUB_REPO --assignee @me --state open \
  --search 'label:"status:to-do" -label:"needs-input"' \
  --json number,title,labels,body --limit 100
```

### Multi-status search

`gh issue list --label` uses AND logic. For OR logic across status labels, use `--search`:
```bash
gh issue list --repo $GITHUB_REPO --assignee @me --state open \
  --search 'label:"status:to-do" OR label:"status:in-progress"' \
  --json number,title,labels,body --limit 100
```

## Updating Descriptions

Update the issue body directly:
```bash
gh issue edit 123 --repo $GITHUB_REPO --body "new description in markdown"
```

The plan MUST go in the issue body (description) — never in a comment.

## Issue Links (Dependencies)

GitHub Issues doesn't have native issue linking. Use these conventions:

- **Blocking**: Add `ralph-blocked` label to dependent issues
- **References**: Mention blocking issues in the body: "Blocked by #42"
- **Auto-close**: Use "Closes #123" in PR descriptions

**Stacked PRs**: When starting a dependent task, check the issue body for "Blocked by #N" references and look for an active `ralph/#N` branch on the remote. If found, branch from that branch instead of the default branch.

## Rate Limiting

The `gh` CLI handles rate limiting automatically with built-in retry logic. If you encounter persistent rate limit errors, wait 30 seconds then retry **once**. If it fails again, output `<promise>ABORT</promise>`.
