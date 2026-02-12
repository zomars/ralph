# BACKLOG PROVIDER: JIRA

You are connected to Jira as the backlog provider. Use the following tools and conventions.

## Tools

- **Search tasks**: `mcp__jira__searchJiraIssuesUsingJql` — pass JQL string and set `maxResults=1`
- **Get task details**: `mcp__jira__getJiraIssue` — fetch full issue by key
- **Edit task**: `mcp__jira__editJiraIssue` — update fields (description, labels)
- **Add comment**: `mcp__jira__addCommentToJiraIssue`
- **Get transitions**: `mcp__jira__getTransitionsForJiraIssue` — always discover available transitions before transitioning
- **Transition status**: `mcp__jira__transitionJiraIssue`

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

## Cloud ID

When calling Jira tools, use the `cloudId` from your Jira configuration. Call `mcp__jira__getAccessibleAtlassianResources` if you need to discover it.
