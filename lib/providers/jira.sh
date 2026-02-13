#!/bin/zsh
# jira.sh — Jira provider for Ralph
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query

# Required env vars for this provider
PROVIDER_ENV_VARS=(JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL)

# Check if tasks exist for the given query
# Args: $1 = JQL query string
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"
  local response
  response=$(curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"jql\":\"$query\",\"maxResults\":10,\"fields\":[\"summary\"]}" \
    "$JIRA_BASE_URL/rest/api/3/search/jql" 2>&1)

  if [[ $? -ne 0 ]]; then
    ralph_error "Provider check failed: $response"
    echo "0"
    return
  fi

  echo "$response" | jq '.issues | length'
}
