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

## Updating Descriptions (ADF Format)

The Jira `description` field requires **Atlassian Document Format (ADF)**, not plain text or markdown.
**Comments accept markdown**, but **descriptions do not**.

Use only these ADF node types — anything else will be rejected:

**Paragraphs:**
```json
{"type": "paragraph", "content": [{"type": "text", "text": "Your text here"}]}
```

**Bold/italic text:**
```json
{"type": "text", "text": "bold text", "marks": [{"type": "strong"}]}
{"type": "text", "text": "italic text", "marks": [{"type": "em"}]}
```

**Headings (level 1-3):**
```json
{"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Section Title"}]}
```

**Bullet lists:**
```json
{"type": "bulletList", "content": [
  {"type": "listItem", "content": [
    {"type": "paragraph", "content": [{"type": "text", "text": "Item one"}]}
  ]},
  {"type": "listItem", "content": [
    {"type": "paragraph", "content": [{"type": "text", "text": "Item two"}]}
  ]}
]}
```

**Full example — use this as a template:**
```json
{
  "description": {
    "type": "doc",
    "version": 1,
    "content": [
      {"type": "heading", "attrs": {"level": 3}, "content": [{"type": "text", "text": "User Story"}]},
      {"type": "paragraph", "content": [{"type": "text", "text": "As a user, I want X so that Y."}]},
      {"type": "heading", "attrs": {"level": 3}, "content": [{"type": "text", "text": "Acceptance Criteria"}]},
      {"type": "bulletList", "content": [
        {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Criterion one"}]}]},
        {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Criterion two"}]}]}
      ]}
    ]
  }
}
```

**IMPORTANT**: Every `listItem` MUST contain a `paragraph` node — never put `text` nodes directly inside `listItem`. Never use `orderedList` — use `bulletList` only. If ADF fails on the first attempt, simplify the ADF structure (use only paragraphs and bullet lists) and retry once. The plan MUST go in the description field — never post it as a comment.

## Cloud ID

When calling Jira tools, use the `cloudId` from your Jira configuration. Call `mcp__jira__getAccessibleAtlassianResources` if you need to discover it.
