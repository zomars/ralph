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
