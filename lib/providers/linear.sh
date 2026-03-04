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

# Check if tasks exist for the given query
# Args: $1 = DSL query string (e.g. "state:Todo assignee:me !label:needs-input")
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"
  local filter

  filter=$(_linear_build_filter "$query")
  if [[ $? -ne 0 || -z "$filter" ]]; then
    ralph_error "Failed to build filter from query: $query"
    echo "0"
    return 0
  fi

  local gql_query
  gql_query=$(jq -nc --argjson filter "$filter" '{
    query: "query($filter:IssueFilter){issues(filter:$filter){nodes{id}}}",
    variables: { filter: $filter }
  }')

  local response
  if ! response=$(curl -s --fail-with-body \
    -H "Content-Type: application/json" \
    -H "Authorization: $LINEAR_API_KEY" \
    -X POST \
    -d "$gql_query" \
    "https://api.linear.app/graphql" 2>&1); then
    ralph_error "Provider check failed: $response"
    echo "0"
    return 0
  fi

  # Check for GraphQL errors
  local errors
  errors=$(echo "$response" | jq -r '.errors[0].message // empty' 2>/dev/null)
  if [[ -n "$errors" ]]; then
    ralph_error "Linear GraphQL error: $errors"
    echo "0"
    return 0
  fi

  echo "$response" | jq '.data.issues.nodes | length'
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
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$routing_json")

  local parts=()
  parts+=('assignee:me')

  # status_in — check if negative form is shorter
  local all_statuses status_in_count all_count
  all_statuses=$(jq -r '.statuses | length' "$routing_json")
  status_in_count=$(echo "$rules" | jq -r '.status_in | length')

  if (( status_in_count == all_statuses )); then
    : # all statuses — no filter needed
  elif (( all_statuses - status_in_count < status_in_count )); then
    # Negative form is shorter — compute excluded statuses
    local excluded
    excluded=$(jq -r --argjson inc "$(echo "$rules" | jq '.status_in')" \
      '[.statuses[] | select(. as $s | $inc | index($s) | not)] | map(gsub(" "; "+")) | join(",")' "$routing_json")
    parts+=("!state:$excluded")
  else
    local included
    included=$(echo "$rules" | jq -r '.status_in | map(gsub(" "; "+")) | join(",")')
    parts+=("state:$included")
  fi

  # labels_include
  local labels_include
  labels_include=$(echo "$rules" | jq -r '.labels_include // null')
  if [[ "$labels_include" != "null" ]]; then
    local inc_list
    inc_list=$(echo "$rules" | jq -r '.labels_include | join(",")')
    parts+=("label:$inc_list")
  fi

  # labels_exclude
  local labels_exclude
  labels_exclude=$(echo "$rules" | jq -r '.labels_exclude // null')
  if [[ "$labels_exclude" != "null" ]]; then
    local exc_list
    exc_list=$(echo "$rules" | jq -r '.labels_exclude | join(",")')
    parts+=("!label:$exc_list")
  fi

  # description_condition
  local desc_cond
  desc_cond=$(echo "$rules" | jq -r '.description_condition // "null"')
  case "$desc_cond" in
    not_empty_and_not_todo) parts+=('!description:empty') ;;
    # empty_or_todo_or_label_needs_planning — not directly filterable in Linear
  esac

  # exclude_blocked
  local exclude_blocked
  exclude_blocked=$(echo "$rules" | jq -r '.exclude_blocked // false')
  if [[ "$exclude_blocked" == "true" ]]; then
    parts+=('!blocked')
  fi

  echo "${parts[*]}"
}
