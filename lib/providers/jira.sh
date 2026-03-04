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

# Check if tasks exist for the given query
# Args: $1 = JQL query string
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"
  local body
  body=$(jq -n --arg jql "$query" '{"jql":$jql,"maxResults":10,"fields":["summary"]}')
  local response
  if ! response=$(curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$body" \
    "$JIRA_BASE_URL/rest/api/3/search/jql" 2>&1); then
    ralph_error "Provider check failed: $response"
    echo "0"
    return 0
  fi

  echo "$response" | jq '.issues | length'
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

  # exclude_blocked
  local exclude_blocked
  exclude_blocked=$(echo "$rules" | jq -r '.exclude_blocked // false')
  if [[ "$exclude_blocked" == "true" ]]; then
    parts+=("issueKey not in linkedIssuesOf('status in (\"To Do\", \"In Progress\")', 'is blocked by')")
  fi

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
