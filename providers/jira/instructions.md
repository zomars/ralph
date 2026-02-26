# BACKLOG PROVIDER: JIRA

You are connected to Jira as the backlog provider. Use the following tools and conventions.

**CRITICAL: Use ONLY `mcp__jira__*` tools (the local Jira server). NEVER use `mcp__claude_ai_jira__*` tools — those hit Anthropic's proxy which is rate-limited. Do NOT call `ToolSearch` for Jira tools — the exact tool names are listed below.**

## Tools

- **Search tasks**: `mcp__jira__searchJiraIssuesUsingJql` — pass JQL string and set `maxResults=1`
- **Get task details**: `mcp__jira__getJiraIssue` — fetch full issue by key
- **Edit task**: `mcp__jira__editJiraIssue` — update fields (description, labels)
- **Add comment**: `mcp__jira__addCommentToJiraIssue`
- **Get transitions**: `mcp__jira__getTransitionsForJiraIssue` — always discover available transitions before transitioning
- **Transition status**: `mcp__jira__transitionJiraIssue`
- **Create issue link**: `mcp__jira__createIssueLink` — link two issues (e.g. "Blocks")

## Status Names

| Generic         | Jira Status  |
| --------------- | ------------ |
| Open/New        | "To Do"      |
| Working         | "In Progress"|
| Review          | "In Review"  |
| Complete        | "Done"       |

## Task Key Format

Jira keys look like `PROJ-123`. Use this as `<TASK-KEY>` in commit messages.

## Query Language

Jira uses JQL (Jira Query Language). All queries in the workflow prompts are written in JQL and can be passed directly to `mcp__jira__searchJiraIssuesUsingJql`.

## Updating Descriptions

Both `editJiraIssue` descriptions and `addCommentToJiraIssue` comments accept **markdown**. Pass a markdown string to `fields.description` — the tool converts it to ADF automatically. **Never pass raw ADF JSON — it will fail.**

The plan MUST go in the description field — never in a comment.

## Issue Links (Dependencies)

Use issue links to express task ordering. The **Planner** creates these when breaking down related work.

**Create a "blocks" link** (task A blocks task B):
```
mcp__jira__createIssueLink(linkType: "Blocks", outwardIssueKey: "PROJ-A", inwardIssueKey: "PROJ-B")
```

The implementer JQL automatically excludes tasks that are blocked by non-Done issues, so dependencies are enforced at the query level — no agent needs to manually check links.

## Uploading Attachments

The MCP tools do not support file attachments. Use `curl` to upload files (screenshots, logs, etc.) to a Jira issue:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "X-Atlassian-Token: no-check" \
  -F "file=@/path/to/screenshot.png" \
  "$JIRA_BASE_URL/rest/api/3/issue/PROJ-123/attachments"
```

The response JSON contains an array of attachment objects. Extract the download URL to embed in comments:

```bash
# Upload and get the self URL
ATTACHMENT_URL=$(curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "X-Atlassian-Token: no-check" \
  -F "file=@/path/to/screenshot.png" \
  "$JIRA_BASE_URL/rest/api/3/issue/PROJ-123/attachments" \
  | jq -r '.[0].content')
```

Then reference the attachment in a comment using markdown: `![description](url)`

## Rate Limiting

If a Jira MCP tool returns a rate-limit error, wait 30 seconds (use `sleep 30` in bash) then retry **once**. If it fails again, output `<promise>ABORT</promise>` — do NOT keep retrying and waste turns.
