# BACKLOG PROVIDER: GITHUB PROJECTS V2

You are connected to GitHub Projects v2 as the backlog provider. Statuses come from the project board's "Status" field (columns). Labels are managed on the underlying issues. Use the `gh` CLI via Bash tool for all operations.

## Tools

All interactions use the `gh` CLI. Run commands via the Bash tool.

- **Search issues**: Use GraphQL to query project items (see Query Language below)
- **Get issue details**: `gh issue view <number> --repo $GITHUB_REPO --json number,title,body,labels,assignees,state,comments`
- **Edit issue (labels)**: `gh issue edit <number> --repo $GITHUB_REPO --add-label "label1" --remove-label "label2"`
- **Add comment**: `gh issue comment <number> --repo $GITHUB_REPO --body "your comment here"`
- **Create issue**: `gh issue create --repo $GITHUB_REPO --title "Title" --body "Description" --assignee @me`

## Status Names

Statuses are managed via the project board's "Status" field, not labels.

| Generic         | Project Status  |
| --------------- | --------------- |
| Open/New        | "Todo"          |
| Working         | "In Progress"   |
| Review          | "In Review"     |
| Complete        | "Done"          |

### Changing Status

To change a project item's status, use a GraphQL mutation via `gh api graphql`:

1. **Find the project item ID and Status field ID**:
```bash
gh api graphql -f query='
  query($owner: String!, $number: Int!, $issueNumber: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
        items(first: 100) {
          nodes {
            id
            content { ... on Issue { number } }
          }
        }
      }
    }
  }
' -f owner="OWNER" -F number=PROJECT_NUMBER -F issueNumber=ISSUE_NUMBER
```

2. **Update the status**:
```bash
gh api graphql -f query='
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
' -f projectId="PROJECT_ID" -f itemId="ITEM_ID" -f fieldId="FIELD_ID" -f optionId="OPTION_ID"
```

**IMPORTANT**: Always discover the project ID, field ID, and option IDs via the query above before attempting to update status. Never hardcode these IDs.

## Task Key Format

GitHub issue keys use the `#123` format. Use `#<number>` as `<TASK-KEY>` in commit messages.

## Query Language

GitHub Projects v2 uses GraphQL. The DSL queries in prompt files describe filter criteria. To search, use `gh api graphql` to query project items and filter with jq.

Example — find "Todo" items assigned to me, excluding `needs-input` label:
```bash
gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        items(first: 100) {
          nodes {
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
              ... on Issue {
                number
                title
                state
                body
                assignees(first: 10) { nodes { login } }
                labels(first: 20) { nodes { name } }
              }
            }
          }
        }
      }
    }
  }
' -f owner="OWNER" -F number=PROJECT_NUMBER \
  | jq '[.data.user.projectV2.items.nodes[]
    | select(.content != null)
    | select(.content.state == "OPEN")
    | select(.fieldValueByName.name == "Todo")
    | select(.content.assignees.nodes | map(.login) | index("YOUR_LOGIN"))
    | select(.content.labels.nodes | map(.name) | index("needs-input") | not)
  ]'
```

**NOTE**: If the project belongs to an organization, replace `user(login: $owner)` with `organization(login: $owner)`.

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

## Adding Issues to the Project

After creating an issue, add it to the project board:
```bash
# Get the issue node ID
ISSUE_ID=$(gh issue view 123 --repo $GITHUB_REPO --json id --jq '.id')

# Add to project
gh api graphql -f query='
  mutation($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
      item { id }
    }
  }
' -f projectId="PROJECT_ID" -f contentId="$ISSUE_ID"
```

## Rate Limiting

The `gh` CLI handles rate limiting automatically with built-in retry logic. If you encounter persistent rate limit errors, wait 30 seconds then retry **once**. If it fails again, output `<promise>ABORT</promise>`.
