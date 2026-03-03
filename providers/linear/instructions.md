# BACKLOG PROVIDER: LINEAR

You are connected to Linear as the backlog provider. Use the following tools and conventions.

**CRITICAL: Use ONLY `mcp__linear__*` tools (the local Linear server). Do NOT call `ToolSearch` for Linear tools — the exact tool names are listed below.**

## Tools

- **Search tasks**: `mcp__linear__searchIssues` — pass a GraphQL `IssueFilter` object and `maxResults`
- **Get task details**: `mcp__linear__getIssue` — fetch full issue by identifier (e.g. `ENG-123`)
- **Update task**: `mcp__linear__updateIssue` — update fields (`stateId`, `labelIds`, `description`, `assigneeId`, `priority`, `title`)
- **Add comment**: `mcp__linear__addComment` — body is markdown
- **Get workflow states**: `mcp__linear__getWorkflowStates` — list states for a team (use to discover `stateId` values)
- **Get labels**: `mcp__linear__getTeamLabels` — list labels for a team (use to discover `labelId` values)
- **Create relation**: `mcp__linear__createRelation` — link two issues (`blocks`, `duplicate`, `related`)

## Status Names

| Generic         | Linear State   |
| --------------- | -------------- |
| Triage          | "Triage"       |
| Open/New        | "Todo"         |
| Working         | "In Progress"  |
| Review          | "In Review"    |
| Complete        | "Done"         |
| Canceled        | "Canceled"     |

## Task Key Format

Linear keys look like `ENG-123` (team key + number). Use this as `<TASK-KEY>` in commit messages.

## Query Language

Linear uses GraphQL filters. The DSL queries in prompt files describe filter criteria. To search, build an `IssueFilter` object and pass it to `mcp__linear__searchIssues`.

Example — find "Todo" issues assigned to me with no `needs-input` label:
```json
{
  "team": { "key": { "eq": "ENG" } },
  "assignee": { "isMe": { "eq": true } },
  "state": { "name": { "in": ["Todo"] } },
  "labels": { "every": { "name": { "nin": ["needs-input"] } } }
}
```

## Updating Issues

### Changing State
1. Call `mcp__linear__getWorkflowStates` with the team key to get state IDs
2. Call `mcp__linear__updateIssue` with `input: { stateId: "<state-uuid>" }`

### Managing Labels
1. Call `mcp__linear__getTeamLabels` with the team key to get label IDs
2. Call `mcp__linear__getIssue` to see current labels
3. Call `mcp__linear__updateIssue` with `input: { labelIds: ["<id1>", "<id2>", ...] }`

**IMPORTANT**: `labelIds` replaces ALL labels — always include existing label IDs you want to keep.

### Descriptions

Linear natively accepts markdown. Pass markdown strings directly to `description` — no conversion needed.

The plan MUST go in the description field — never in a comment.

## Issue Relations (Dependencies)

Use issue relations to express task ordering. The **Planner** creates these when breaking down related work.

**Create a "blocks" link** (task A blocks task B):
```
mcp__linear__createRelation(issueId: "ENG-1", relatedIssueId: "ENG-2", type: "blocks")
```

**Stacked PRs**: When starting a dependent task, the implementer checks issue relations for "blocks" links and looks for an active `ralph/<BLOCKER-KEY>` branch on the remote. If found, it branches from that branch instead of the default branch, and the PR targets the blocker's branch.

## Rate Limiting

If a Linear MCP tool returns a rate-limit error, wait 30 seconds (use `sleep 30` in bash) then retry **once**. If it fails again, output `<promise>ABORT</promise>` — do NOT keep retrying and waste turns.
