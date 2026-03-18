#!/bin/zsh
# linear.sh — Linear provider for Ralph
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query

# Required env vars for this provider
PROVIDER_ENV_VARS=(LINEAR_API_KEY LINEAR_TEAM_KEY)

# MCP server required by this provider
PROVIDER_MCP_NAME=linear
PROVIDER_MCP_CMD=ralph-linear-mcp

# Fetch full task data for the given query
# Args: $1 = DSL query string, $2 = max results (default 10)
# Returns: JSON with .issues[] array (normalized to match gated-loop expectations)
provider_fetch_tasks() {
  local query="$1"
  local max_results="${2:-10}"
  local filter

  filter=$(_linear_build_filter "$query")
  if [[ $? -ne 0 || -z "$filter" ]]; then
    ralph_error "Failed to build filter from query: $query"
    echo '{"issues":[]}'
    return 1
  fi

  local gql_query
  gql_query=$(jq -nc --argjson filter "$filter" --argjson first "$max_results" '{
    query: "query($filter:IssueFilter,$first:Int){issues(filter:$filter,first:$first){nodes{id,identifier,title,description,state{name,type},priority,labels{nodes{name}},relations{nodes{type,relatedIssue{identifier,title,state{name,type}}}},parent{identifier},createdAt,updatedAt,comments{nodes{body,user{name},createdAt}}}}}",
    variables: { filter: $filter, first: $first }
  }')

  local response
  if ! response=$(curl -s --fail-with-body \
    -H "Content-Type: application/json" \
    -H "Authorization: $LINEAR_API_KEY" \
    -X POST \
    -d "$gql_query" \
    "https://api.linear.app/graphql" 2>&1); then
    ralph_error "Provider fetch failed: $response"
    echo '{"issues":[]}'
    return 1
  fi

  local errors
  errors=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null)
  if [[ -n "$errors" ]]; then
    ralph_error "Linear GraphQL error: $errors"
    echo '{"issues":[]}'
    return 1
  fi

  # Normalize to { issues: [...] } for gated-loop compatibility
  echo "$response" | jq '{ issues: [.data.issues.nodes[] | {
    key: .identifier,
    fields: {
      summary: .title,
      description: .description,
      status: { name: .state.name, statusCategory: { key: (if .state.type == "completed" then "done" elif .state.type == "started" then "indeterminate" else "new" end) } },
      priority: { name: (if .priority == 1 then "Urgent" elif .priority == 2 then "High" elif .priority == 3 then "Medium" else "Low" end) },
      labels: [.labels.nodes[]? | { name: .name }],
      parent: (if .parent then { key: .parent.identifier } else null end),
      created: .createdAt,
      updated: .updatedAt,
      comment: { comments: [.comments.nodes[]? | { author: { displayName: .user.name }, created: .createdAt, body: .body }] },
      issuelinks: [.relations.nodes[]? | {
        type: { name: .type, inward: (if .type == "blocks" then "is blocked by" else .type end) },
        outwardIssue: { key: .relatedIssue.identifier, fields: { summary: .relatedIssue.title, status: { name: .relatedIssue.state.name, statusCategory: { key: (if .relatedIssue.state.type == "completed" then "done" elif .relatedIssue.state.type == "started" then "indeterminate" else "new" end) } } } }
      }]
    }
  }] }'
}

# Check if tasks exist for the given query
# Args: $1 = DSL query string (e.g. "state:Todo assignee:me !label:needs-input")
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"
  local response
  response=$(provider_fetch_tasks "$query" 10)
  echo "$response" | jq '.issues | length'
}

# Check if an issue has unfinished blockers
# Args: $1 = path to JSON file (normalized format), $2 = blocker_check mode (unused)
# Returns: 0 if no blockers, 1 if blocked
provider_check_blockers() {
  local issue_file="$1"
  local blocked_count
  blocked_count=$(jq '[
    .fields.issuelinks[]?
    | select(.type.inward == "is blocked by")
    | select(.outwardIssue.fields.status.statusCategory.key != "done")
  ] | length' "$issue_file")
  [[ "$blocked_count" -eq 0 ]]
}

# Write issue data to KB directory
# Args: $1 = path to JSON file (normalized format), $2 = KB directory path
provider_write_kb() {
  local issue_file="$1"
  local kb_dir="$2"

  local task_key task_summary task_status task_priority task_labels task_parent
  task_key=$(jq -r '.key' "$issue_file")
  task_summary=$(jq -r '.fields.summary' "$issue_file")
  task_status=$(jq -r '.fields.status.name' "$issue_file")
  task_priority=$(jq -r '.fields.priority.name // "None"' "$issue_file")
  task_labels=$(jq -r '[.fields.labels[]?.name] | join(", ")' "$issue_file")
  task_parent=$(jq -r '.fields.parent.key // "None"' "$issue_file")

  cat > "$kb_dir/task.md" <<EOF
# $task_key: $task_summary

- **Status**: $task_status
- **Priority**: $task_priority
- **Labels**: $task_labels
- **Parent**: $task_parent
EOF

  # Linear descriptions are markdown already
  local desc
  desc=$(jq -r '.fields.description // "(no description)"' "$issue_file")
  echo "$desc" > "$kb_dir/description.md"

  # comments.md
  local comments_count
  comments_count=$(jq '.fields.comment.comments | length' "$issue_file")
  if [[ "$comments_count" -gt 0 ]]; then
    jq -r '.fields.comment.comments[] |
      "### \(.author.displayName) (\(.created | split("T")[0]))\n\n\(.body)\n\n---\n"
    ' "$issue_file" > "$kb_dir/comments.md"
  else
    echo "(no comments)" > "$kb_dir/comments.md"
  fi

  # links.json
  jq '[
    .fields.issuelinks[]? | {
      type: .type.name,
      direction: "outward",
      inward_desc: .type.inward,
      key: .outwardIssue.key,
      summary: .outwardIssue.fields.summary,
      status: .outwardIssue.fields.status.name,
      statusCategory: .outwardIssue.fields.status.statusCategory.key
    }
  ]' "$issue_file" > "$kb_dir/links.json"

  # meta.json
  jq '{
    key: .key,
    status: .fields.status.name,
    statusCategory: .fields.status.statusCategory.key,
    priority: .fields.priority.name,
    labels: [.fields.labels[]?.name],
    parent_key: (.fields.parent.key // null),
    created: .fields.created,
    updated: .fields.updated
  }' "$issue_file" > "$kb_dir/meta.json"
}

# Render issue data as inline markdown for the initial message
# Args: $1 = path to JSON file (normalized format)
# Returns: markdown string to stdout
provider_render_kb() {
  local issue_file="$1"

  local task_key task_summary task_status task_priority task_labels task_parent
  task_key=$(jq -r '.key' "$issue_file")
  task_summary=$(jq -r '.fields.summary' "$issue_file")
  task_status=$(jq -r '.fields.status.name' "$issue_file")
  task_priority=$(jq -r '.fields.priority.name // "None"' "$issue_file")
  task_labels=$(jq -r '[.fields.labels[]?.name] | join(", ")' "$issue_file")
  task_parent=$(jq -r '.fields.parent.key // "None"' "$issue_file")

  local desc_md
  desc_md=$(jq -r '.fields.description // "(no description)"' "$issue_file")

  local comments_md=""
  local comments_count
  comments_count=$(jq '.fields.comment.comments | length' "$issue_file")
  if [[ "$comments_count" -gt 0 ]]; then
    comments_md=$(jq -r '
      .fields.comment.comments[] |
      "### \(.author.displayName) (\(.created | split("T")[0]))\n\n\(.body)\n\n---"
    ' "$issue_file")
  fi

  local blocker_keys
  blocker_keys=$(jq -r '
    [.fields.issuelinks[]?
     | select(.type.inward == "is blocked by")
     | .outwardIssue.key] | join(" ")
  ' "$issue_file")
  local blockers_md=""
  if [[ -n "$blocker_keys" ]]; then
    blockers_md="
## Blocker Keys (for stacked PR branch setup)
$blocker_keys"
  fi

  cat <<EOF
# YOUR ASSIGNED TASK: $task_key

**$task_summary**

| Field | Value |
|-------|-------|
| Status | $task_status |
| Priority | $task_priority |
| Labels | $task_labels |
| Parent | $task_parent |

## Description

$desc_md

## Comments

${comments_md:-(no comments)}
${blockers_md}
EOF
}

# Build a GraphQL IssueFilter JSON from the DSL query string.
# Always injects team scoping via LINEAR_TEAM_KEY.
#
# Supported tokens:
#   state:Todo,In+Progress        → state: { name: { in: ["Todo", "In Progress"] } }
#   !state:Done,Canceled          → state: { name: { nin: [...] } }
#   Note: use + for spaces in multi-word values (e.g. In+Progress)
#   label:needs-tests             → labels: { some: { name: { in: [...] } } }
#   !label:x,y                    → labels: { every: { name: { nin: [...] } } }
#   assignee:me                   → assignee: { isMe: { eq: true } }
#   description:empty             → description: { null: true } (custom post-filter)
#   !description:empty            → description: { null: false }
#   !blocked                      → (not expressible in filter — informational only)
_linear_build_filter() {
  local query="$1"
  local filter_parts=()
  local json_array values

  # Always scope to team
  filter_parts+=("\"team\":{\"key\":{\"eq\":\"$LINEAR_TEAM_KEY\"}}")

  local token
  for token in ${(z)query}; do
    case "$token" in
      state:*)
        values="${token#state:}"
        json_array=$(echo "$values" | tr '+' ' ' | tr ',' '\n' | jq -R . | jq -sc .)
        filter_parts+=("\"state\":{\"name\":{\"in\":$json_array}}")
        ;;
      !state:*)
        values="${token#!state:}"
        json_array=$(echo "$values" | tr '+' ' ' | tr ',' '\n' | jq -R . | jq -sc .)
        filter_parts+=("\"state\":{\"name\":{\"nin\":$json_array}}")
        ;;
      label:*)
        values="${token#label:}"
        json_array=$(echo "$values" | tr ',' '\n' | jq -R . | jq -sc .)
        filter_parts+=("\"labels\":{\"some\":{\"name\":{\"in\":$json_array}}}")
        ;;
      !label:*)
        values="${token#!label:}"
        json_array=$(echo "$values" | tr ',' '\n' | jq -R . | jq -sc .)
        filter_parts+=("\"labels\":{\"every\":{\"name\":{\"nin\":$json_array}}}")
        ;;
      assignee:me)
        filter_parts+=("\"assignee\":{\"isMe\":{\"eq\":true}}")
        ;;
      description:empty)
        # Linear doesn't have a direct "description is null" filter,
        # but we can approximate with a custom null check
        filter_parts+=("\"description\":{\"null\":true}")
        ;;
      !description:empty)
        filter_parts+=("\"description\":{\"null\":false}")
        ;;
      !blocked)
        # Not expressible as a Linear filter — agents handle this in their workflow
        ;;
      *)
        ralph_error "Unknown DSL token: $token"
        ;;
    esac
  done

  # Join filter parts into a JSON object
  local joined=""
  local part
  for part in "${filter_parts[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="$joined,$part"
    else
      joined="$part"
    fi
  done

  echo "{$joined}"
}

# Generate DSL query from rules in routing.json
# Args: $1 = agent key
# Returns: DSL string for _linear_build_filter()
provider_rules_to_query() {
  local agent="$1"
  # Get canonical DSL, then prepend assignee and remap status: → state: for Linear
  local dsl
  dsl=$(ralph_rules_to_dsl "$agent")
  # Linear uses state: instead of status:
  dsl="${dsl//status:/state:}"
  dsl="${dsl//!status:/!state:}"
  echo "assignee:me $dsl"
}
