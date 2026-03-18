#!/bin/zsh
# jira.sh — Jira provider for Ralph
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query

# Required env vars for this provider
PROVIDER_ENV_VARS=(JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL)

# MCP server required by this provider
PROVIDER_MCP_NAME=jira
PROVIDER_MCP_CMD=ralph-jira-mcp

# Fetch full task data for the given query
# Args: $1 = JQL query string, $2 = max results (default 10)
# Returns: raw JSON response from Jira search API
provider_fetch_tasks() {
  local query="$1"
  local max_results="${2:-10}"
  local body
  body=$(jq -n --arg jql "$query" --argjson max "$max_results" \
    '{"jql":$jql,"maxResults":$max,"fields":["summary","status","labels","priority","issuelinks","comment","parent","attachment","description","created","updated"]}')
  # Write directly to a temp file — never store Jira JSON in a zsh variable.
  # Jira ADF descriptions contain literal newlines inside JSON strings that
  # get corrupted by zsh variable expansion + echo.
  local tmp
  tmp=$(mktemp)
  if ! curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$body" \
    "$JIRA_BASE_URL/rest/api/3/search/jql" > "$tmp" 2>&1; then
    ralph_error "Provider fetch failed: $(cat "$tmp")"
    rm -f "$tmp"
    echo '{"issues":[]}'
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# Check if tasks exist for the given query
# Args: $1 = JQL query string
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"
  local response
  response=$(provider_fetch_tasks "$query" 10)
  echo "$response" | jq '.issues | length'
}

# Check if an issue has unfinished blockers
# Args: $1 = path to JSON file containing single issue object
# Returns: 0 if no blockers (safe to work), 1 if blocked
provider_check_blockers() {
  local issue_file="$1"
  local blocked_count
  # In Jira's link model, when type.inward == "is blocked by":
  #   inwardIssue = the issue that blocks us (our blocker)
  #   outwardIssue = the issue we block
  blocked_count=$(jq '[
    .fields.issuelinks[]?
    | select(.type.inward == "is blocked by" and .inwardIssue)
    | select(.inwardIssue.fields.status.statusCategory.key != "done")
  ] | length' "$issue_file")
  [[ "$blocked_count" -eq 0 ]]
}

# Write issue data to KB directory
# Args: $1 = single issue JSON object, $2 = KB directory path
provider_write_kb() {
  local issue_json="$1"
  local kb_dir="$2"

  # task.md — key, summary, status, priority, labels, parent
  local task_key task_summary task_status task_priority task_labels task_parent
  task_key=$(echo "$issue_json" | jq -r '.key')
  task_summary=$(echo "$issue_json" | jq -r '.fields.summary')
  task_status=$(echo "$issue_json" | jq -r '.fields.status.name')
  task_priority=$(echo "$issue_json" | jq -r '.fields.priority.name // "None"')
  task_labels=$(echo "$issue_json" | jq -r '[.fields.labels[]? | if type == "object" then .name else . end] | join(", ")')
  task_parent=$(echo "$issue_json" | jq -r '.fields.parent.key // "None"')

  cat > "$kb_dir/task.md" <<EOF
# $task_key: $task_summary

- **Status**: $task_status
- **Priority**: $task_priority
- **Labels**: $task_labels
- **Parent**: $task_parent
EOF

  # Batch-convert all ADF bodies (description + comments) in one Node call
  local comments_count
  comments_count=$(echo "$issue_json" | jq '.fields.comment.comments | length')

  # Build array: [description_adf, comment0_adf, comment1_adf, ...]
  # Pipe through Node once, write result to temp file to avoid shell mangling
  local batch_file="$kb_dir/_batch.json"
  echo "$issue_json" | jq '[.fields.description] + [.fields.comment.comments[]?.body]' \
    | ralph-adf-to-md --batch > "$batch_file" 2>/dev/null || true
  if ! jq empty "$batch_file" 2>/dev/null; then
    echo '[]' > "$batch_file"
  fi

  # description.md — first element
  jq -r '.[0] // "(no description)"' "$batch_file" > "$kb_dir/description.md"

  # comments.md — remaining elements, merged with metadata via jq
  if [[ "$comments_count" -gt 0 ]]; then
    echo "$issue_json" | jq -r --slurpfile bodies "$batch_file" '
      [.fields.comment.comments | to_entries[] | {
        author: .value.author.displayName,
        date: (.value.created | split("T")[0]),
        body: ($bodies[0][.key + 1] // "(conversion failed)")
      }] | .[] | "### \(.author) (\(.date))\n\n\(.body)\n\n---\n"
    ' > "$kb_dir/comments.md"
  else
    echo "(no comments)" > "$kb_dir/comments.md"
  fi
  rm -f "$batch_file"

  # links.json — [{type, direction, key, summary, status, statusCategory}]
  echo "$issue_json" | jq '[
    .fields.issuelinks[]? | (
      if .outwardIssue then
        {type: .type.name, direction: "outward", inward_desc: .type.inward, outward_desc: .type.outward,
         key: .outwardIssue.key, summary: .outwardIssue.fields.summary,
         status: .outwardIssue.fields.status.name,
         statusCategory: .outwardIssue.fields.status.statusCategory.key}
      elif .inwardIssue then
        {type: .type.name, direction: "inward", inward_desc: .type.inward, outward_desc: .type.outward,
         key: .inwardIssue.key, summary: .inwardIssue.fields.summary,
         status: .inwardIssue.fields.status.name,
         statusCategory: .inwardIssue.fields.status.statusCategory.key}
      else empty end
    )
  ]' > "$kb_dir/links.json"

  # meta.json — machine-readable metadata
  echo "$issue_json" | jq '{
    key: .key,
    status: .fields.status.name,
    statusCategory: .fields.status.statusCategory.key,
    priority: .fields.priority.name,
    labels: [.fields.labels[]? | if type == "object" then .name else . end],
    parent_key: (.fields.parent.key // null),
    created: .fields.created,
    updated: .fields.updated
  }' > "$kb_dir/meta.json"
}

# Render issue data as inline markdown for the initial message
# Args: $1 = path to JSON file containing single issue object
# Returns: markdown string to stdout
provider_render_kb() {
  local issue_file="$1"

  local task_key task_summary task_status task_priority task_labels task_parent
  task_key=$(jq -r '.key' "$issue_file")
  task_summary=$(jq -r '.fields.summary' "$issue_file")
  task_status=$(jq -r '.fields.status.name' "$issue_file")
  task_priority=$(jq -r '.fields.priority.name // "None"' "$issue_file")
  task_labels=$(jq -r '[.fields.labels[]? | if type == "object" then .name else . end] | join(", ")' "$issue_file")
  task_parent=$(jq -r '.fields.parent.key // "None"' "$issue_file")

  # Batch-convert all ADF (description + comments) in one Node call
  local batch_file
  batch_file=$(mktemp)
  jq '[.fields.description] + [.fields.comment.comments[]?.body]' "$issue_file" \
    | ralph-adf-to-md --batch > "$batch_file" 2>/dev/null || true
  # Validate output — ralph-adf-to-md may produce non-JSON on failure
  if ! jq empty "$batch_file" 2>/dev/null; then
    echo '[]' > "$batch_file"
  fi

  local desc_md
  desc_md=$(jq -r '.[0] // "(no description)"' "$batch_file")

  local comments_md=""
  local comments_count
  comments_count=$(jq '.fields.comment.comments | length' "$issue_file")
  if [[ "$comments_count" -gt 0 ]]; then
    comments_md=$(jq -r --slurpfile bodies "$batch_file" '
      [.fields.comment.comments | to_entries[] | {
        author: .value.author.displayName,
        date: (.value.created | split("T")[0]),
        body: ($bodies[0][.key + 1] // "(conversion failed)")
      }] | .[] | "### \(.author) (\(.date))\n\n\(.body)\n\n---"
    ' "$issue_file")
  fi
  rm -f "$batch_file"

  # Blocker branches for stacked PRs
  local blockers_md=""
  local blocker_keys
  blocker_keys=$(jq -r '
    [.fields.issuelinks[]?
     | select(.type.inward == "is blocked by" and .inwardIssue)
     | .inwardIssue.key] | join(" ")
  ' "$issue_file")
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

# Generate JQL from rules in routing.json
# Args: $1 = agent key
# Returns: JQL string
provider_rules_to_query() {
  local agent="$1"
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$routing_json")

  local parts=()
  parts+=('assignee = currentUser()')

  # status_in
  local status_jql
  status_jql=$(echo "$rules" | jq -r '.status_in | map("\"" + . + "\"") | join(", ")')
  parts+=("status in ($status_jql)")

  # description_condition
  local desc_cond
  desc_cond=$(echo "$rules" | jq -r '.description_condition // "null"')
  case "$desc_cond" in
    empty_or_todo_or_label_needs_planning)
      parts+=('((description is EMPTY OR description ~ "TODO") OR labels = "needs-planning")')
      ;;
    not_empty_and_not_todo)
      parts+=('(description is not EMPTY AND description !~ "TODO")')
      ;;
  esac

  # labels_include
  local labels_include
  labels_include=$(echo "$rules" | jq -r '.labels_include // null')
  if [[ "$labels_include" != "null" ]]; then
    local label
    for label in $(echo "$rules" | jq -r '.labels_include[]'); do
      parts+=("labels = \"$label\"")
    done
  fi

  # labels_exclude — uses the Jira gotcha: (labels is EMPTY OR labels not in (...))
  local labels_exclude
  labels_exclude=$(echo "$rules" | jq -r '.labels_exclude // null')
  if [[ "$labels_exclude" != "null" ]]; then
    local exclude_list
    exclude_list=$(echo "$rules" | jq -r '.labels_exclude | map("\"" + . + "\"") | join(", ")')
    parts+=("(labels is EMPTY OR labels not in ($exclude_list))")
  fi

  # exclude_blocked — handled by shell-level provider_check_blockers in the gated loop.
  # linkedIssuesOf() in JQL is a no-op for this use case (returns empty set regardless
  # of direction name used), so we don't emit it.

  # Build the query
  local query=""
  local part
  for part in "${parts[@]}"; do
    if [[ -n "$query" ]]; then
      query="$query AND $part"
    else
      query="$part"
    fi
  done

  # order_by
  local order_by
  order_by=$(echo "$rules" | jq -r '.order_by // "null"')
  case "$order_by" in
    priority_desc) query="$query ORDER BY priority DESC" ;;
    created_desc)  query="$query ORDER BY createdDate DESC" ;;
    updated_desc)  query="$query ORDER BY updated DESC" ;;
  esac

  echo "$query"
}
