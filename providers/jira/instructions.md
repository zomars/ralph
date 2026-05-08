# BACKLOG PROVIDER: JIRA

You are connected to Jira as the backlog provider. Use the following tools and conventions.

**CRITICAL: Use ONLY `mcp__jira__*` tools (the local Jira server). NEVER use `mcp__claude_ai_jira__*` tools — those hit Anthropic's proxy which is rate-limited. Do NOT call `ToolSearch` for Jira tools — the exact tool names are listed below.**

## Task Context

Your assigned task is pre-loaded in the KB directory (path in initial message). Read KB files for your assigned task. All task context you need is in the KB — do NOT query Jira for task details.

## Tools

- **Do NOT use**: `mcp__jira__searchJiraIssuesUsingJql`, `mcp__jira__getJiraIssue` — task context is in the KB. These waste turns and tokens.
- **Edit task**: `mcp__jira__editJiraIssue` — update fields (description, labels)
- **Add comment**: `mcp__jira__addCommentToJiraIssue`
- **Get transitions**: `mcp__jira__getTransitionsForJiraIssue` — always discover available transitions before transitioning
- **Transition status**: `mcp__jira__transitionJiraIssue`
- **Create issue**: `mcp__jira__createJiraIssue` — create a new issue (subtask, task, story) with optional parent
- **Create blocker link**: `mcp__jira__createBlockedByLink` — declare `blockedKey` is blocked by `blockerKey` (the only sanctioned way to wire blockers)
- **Create issue link**: `mcp__jira__createIssueLink` — link two issues for non-blocker types ("Relates", "Duplicates", "Causes"); refuses "Blocks"
- **Create remote link**: `mcp__jira__createRemoteLink` — attach an external URL (e.g. GitHub PR) to an issue
- **Add attachment**: `mcp__jira__addAttachmentToJiraIssue` — upload a file (screenshot, log, etc.) to an issue

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

Ralph speaks dependencies in **one direction only**: **"X is blocked by Y."** Never write or think "Y blocks X" — even though Jira supports that phrasing, Ralph agents use a single direction so links cannot be wired backwards.

**Create a "blocked by" link** (`PROJ-B` is blocked by `PROJ-A` — A must finish first):
```
mcp__jira__createBlockedByLink(blockedKey: "PROJ-B", blockerKey: "PROJ-A")
```

The raw `createIssueLink` tool refuses `Blocks` linkType and returns an error directing you here. Use it only for non-blocker types (Relates, Duplicates, Causes).

The implementer JQL excludes tasks whose blockers are still in "To Do" or "In Progress". Once a blocker reaches "In Review" (has an open PR) or "Done", the dependent task becomes available.

**Stacked PRs**: When starting a dependent task, the implementer checks `fields.issuelinks` for "is blocked by" links and looks for an active `ralph/<BLOCKER-KEY>` branch on the remote. If found, it branches from that branch instead of the default branch, and the PR targets the blocker's branch. After the blocker is merged, the reviewer rebases child PRs onto the default branch and updates their PR base.

## Uploading Attachments

Use `mcp__jira__addAttachmentToJiraIssue` to upload files (screenshots, logs, etc.) to a Jira issue. The response includes the `content` URL for each attachment — use it to embed in comments with markdown: `![description](url)`

## Tool Parameter Reference

Call these tools exactly as shown — wrong parameter names or types waste turns.

### getTransitionsForJiraIssue
```json
{ "issueIdOrKey": "PROJ-123" }
```

### transitionJiraIssue
```json
{ "issueIdOrKey": "PROJ-123", "transition": { "id": "21" } }
```
`transition` is an **object** with an `id` string — not a bare ID, not a JSON string.

### editJiraIssue
```json
{ "issueIdOrKey": "PROJ-123", "fields": { "labels": ["label-a", "label-b"] } }
```
Labels are an **array of strings** — not objects like `[{"name":"x"}]`.

### addCommentToJiraIssue
```json
{ "issueIdOrKey": "PROJ-123", "commentBody": "Markdown comment here" }
```

### createJiraIssue
```json
{ "projectKey": "PROJ", "issueTypeName": "Task", "summary": "Title", "description": "Markdown", "labels": ["label"] }
```

### addAttachmentToJiraIssue
```json
{ "issueIdOrKey": "PROJ-123", "filePath": "/path/to/file.png" }
```

## Rate Limiting

If a Jira MCP tool returns a rate-limit error, wait 30 seconds (use `sleep 30` in bash) then retry **once**. If it fails again, output `<promise>ABORT</promise>` — do NOT keep retrying and waste turns.
