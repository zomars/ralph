#!/bin/zsh
# jira.sh — Jira provider for Ralph

# ADF → Markdown conversion via jq (no Node dependency)
_jira_adf_to_md() {
  # Args: $1 = path to JSON file, $2 = jq expression to extract ADF node
  # Returns: markdown string
  jq -r "$2" "$1" | jq -r -f "$RALPH_HOME/lib/adf-to-md.jq" 2>/dev/null || echo "(conversion failed)"
}
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query

# Required env vars for this provider
PROVIDER_ENV_VARS=(JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL)

# MCP server required by this provider
PROVIDER_MCP_NAME=ralph
PROVIDER_MCP_CMD=ralph-mcp

# Fetch full task data for the given query
# Args: $1 = JQL query string, $2 = max results (default 10)
# Returns: raw JSON response from Jira search API
provider_fetch_tasks() {
  local query="$1"
  local max_results="${2:-10}"
  local body
  body=$(jq -n --arg jql "$query" --argjson max "$max_results" \
    '{"jql":$jql,"maxResults":$max,"fields":["summary","status","labels","priority","issuelinks","comment","parent","attachment","description","created","updated","subtasks"]}')
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
  local tmp
  tmp=$(mktemp)
  provider_fetch_tasks "$query" 10 > "$tmp"
  local count
  count=$(jq '.issues | length' "$tmp" 2>/dev/null || echo "0")
  rm -f "$tmp"
  echo "$count"
}

# Get keys of unresolved blockers for an issue
# Args: $1 = path to JSON file, $2 = blocker_check mode
# Outputs: space-separated blocker keys (empty if none)
provider_get_unresolved_blocker_keys() {
  local issue_file="$1"
  local mode="${2:-done}"

  local blocker_keys
  blocker_keys=$(jq -r '[
    .fields.issuelinks[]?
    | select(.type.inward == "is blocked by" and .inwardIssue)
    | .inwardIssue.key
  ] | join(" ")' "$issue_file")
  [[ -z "$blocker_keys" ]] && return 0

  case "$mode" in
    no_needs_planning)
      local key_list=""
      for k in ${=blocker_keys}; do
        [[ -n "$key_list" ]] && key_list="$key_list, "
        key_list="$key_list\"$k\""
      done
      local jql="key in ($key_list) AND labels = \"needs-planning\""
      local body
      body=$(jq -n --arg jql "$jql" '{"jql":$jql,"maxResults":50,"fields":["key"]}')
      local tmp
      tmp=$(mktemp)
      curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST -d "$body" \
        "$JIRA_BASE_URL/rest/api/3/search/jql" > "$tmp" 2>/dev/null || true
      jq -r '[.issues[].key] | join(" ")' "$tmp" 2>/dev/null
      rm -f "$tmp"
      ;;
    *)
      jq -r '[
        .fields.issuelinks[]?
        | select(.type.inward == "is blocked by" and .inwardIssue)
        | select(.inwardIssue.fields.issuetype.name != "Epic")
        | select(.inwardIssue.fields.status.statusCategory.key != "done")
        | .inwardIssue.key
      ] | join(" ")' "$issue_file"
      ;;
  esac
}

# Check if an issue has unfinished blockers
# Args: $1 = path to JSON file containing single issue object
#       $2 = blocker_check mode: "done" (default) or "no_needs_planning"
# Returns: 0 if no blockers (safe to work), 1 if blocked
provider_check_blockers() {
  local issue_file="$1"
  local mode="${2:-done}"

  # Extract blocker keys
  local blocker_keys
  blocker_keys=$(jq -r '[
    .fields.issuelinks[]?
    | select(.type.inward == "is blocked by" and .inwardIssue)
    | .inwardIssue.key
  ] | join(" ")' "$issue_file")
  [[ -z "$blocker_keys" ]] && return 0  # no blockers

  case "$mode" in
    no_needs_planning)
      # Blocker is "cleared" once it no longer has the needs-planning label.
      # Since Jira search doesn't return labels for linked issues, we query
      # blockers that still have needs-planning via a single JQL call.
      local key_list=""
      for k in ${=blocker_keys}; do
        [[ -n "$key_list" ]] && key_list="$key_list, "
        key_list="$key_list\"$k\""
      done
      local jql="key in ($key_list) AND labels = \"needs-planning\""
      local body
      body=$(jq -n --arg jql "$jql" '{"jql":$jql,"maxResults":1,"fields":["key"]}')
      local tmp
      tmp=$(mktemp)
      curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST -d "$body" \
        "$JIRA_BASE_URL/rest/api/3/search/jql" > "$tmp" 2>/dev/null || true
      local still_planning
      still_planning=$(jq '.issues | length' "$tmp" 2>/dev/null)
      rm -f "$tmp"
      [[ "${still_planning:-0}" -eq 0 ]]
      ;;
    *)
      # Default: blocked until all blockers reach "done" status category
      local blocked_count
      blocked_count=$(jq '[
        .fields.issuelinks[]?
        | select(.type.inward == "is blocked by" and .inwardIssue)
        | select(.inwardIssue.fields.issuetype.name != "Epic")
        | select(.inwardIssue.fields.status.statusCategory.key != "done")
      ] | length' "$issue_file")
      [[ "$blocked_count" -eq 0 ]]
      ;;
  esac
}

# Mark a task as blocked via Jira REST API (used by loop guards)
# Args: $1 = issue key, $2 = reason string
provider_mark_blocked() {
  local task_key="$1" reason="$2"
  local jira_url="${JIRA_BASE_URL}/rest/api/3"
  local auth_header
  auth_header="Authorization: Basic $(printf '%s' "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64)"

  # Get current labels and append ralph-blocked
  local current_labels new_labels
  current_labels=$(curl -s -H "$auth_header" \
    "$jira_url/issue/$task_key?fields=labels" \
    | jq -r '.fields.labels // []')
  new_labels=$(echo "$current_labels" | jq '. + ["ralph-blocked"] | unique')

  curl -s -X PUT -H "$auth_header" -H "Content-Type: application/json" \
    "$jira_url/issue/$task_key" \
    -d "{\"fields\":{\"labels\":$new_labels}}" >/dev/null 2>&1 || true

  # Add comment explaining why
  local comment_body
  comment_body=$(jq -n --arg text "RALPH loop guard: $reason" \
    '{body:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$text}]}]}}')
  curl -s -X POST -H "$auth_header" -H "Content-Type: application/json" \
    "$jira_url/issue/$task_key/comment" -d "$comment_body" >/dev/null 2>&1 || true

  ralph_log "Marked $task_key as ralph-blocked: $reason"
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

  # Convert ADF description to markdown
  local desc_tmp
  desc_tmp=$(mktemp)
  echo "$issue_json" > "$desc_tmp"
  local desc_md
  desc_md=$(_jira_adf_to_md "$desc_tmp" '.fields.description')
  echo "${desc_md:-(no description)}" > "$kb_dir/description.md"

  # Convert ADF comments to markdown
  local comments_count
  comments_count=$(echo "$issue_json" | jq '.fields.comment.comments | length')
  if [[ "$comments_count" -gt 0 ]]; then
    local i=0 author date body
    while (( i < comments_count )); do
      author=$(jq -r ".fields.comment.comments[$i].author.displayName" "$desc_tmp")
      date=$(jq -r ".fields.comment.comments[$i].created | split(\".\")[0] | gsub(\"T\";\" \")" "$desc_tmp")
      body=$(_jira_adf_to_md "$desc_tmp" ".fields.comment.comments[$i].body")
      echo "### $author ($date)"
      echo ""
      echo "$body"
      echo ""
      echo "---"
      echo ""
      i=$((i + 1))
    done > "$kb_dir/comments.md"
  else
    echo "(no comments)" > "$kb_dir/comments.md"
  fi
  rm -f "$desc_tmp"

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

  # Convert ADF description to markdown
  local desc_md
  desc_md=$(_jira_adf_to_md "$issue_file" '.fields.description')
  desc_md="${desc_md:-(no description)}"

  # Convert ADF comments to markdown
  local comments_md=""
  local comments_count
  comments_count=$(jq '.fields.comment.comments | length' "$issue_file")
  if [[ "$comments_count" -gt 0 ]]; then
    local i=0 author date body
    while (( i < comments_count )); do
      author=$(jq -r ".fields.comment.comments[$i].author.displayName" "$issue_file")
      date=$(jq -r ".fields.comment.comments[$i].created | split(\".\")[0] | gsub(\"T\";\" \")" "$issue_file")
      body=$(_jira_adf_to_md "$issue_file" ".fields.comment.comments[$i].body")
      comments_md+="### $author ($date)\n\n$body\n\n---\n"
      i=$((i + 1))
    done
  fi

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
