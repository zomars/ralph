#!/bin/zsh
# file.sh — File-based provider for Ralph
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query

# Required env vars for this provider
PROVIDER_ENV_VARS=(RALPH_PRD_FILE)

# Default to ./prd.md if not set
export RALPH_PRD_FILE="${RALPH_PRD_FILE:-./prd.md}"

# Check if tasks exist for the given query
# Args: $1 = query string (e.g., "status:to-do label:needs-tests")
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"

  if [[ ! -f "$RALPH_PRD_FILE" ]]; then
    ralph_error "PRD file not found: $RALPH_PRD_FILE"
    echo "0"
    return
  fi

  local parser_script="$RALPH_HOME/lib/providers/file-query.awk"
  if [[ ! -f "$parser_script" ]]; then
    ralph_error "Query parser not found: $parser_script"
    echo "0"
    return
  fi

  awk -v query="$query" -f "$parser_script" "$RALPH_PRD_FILE"
}
