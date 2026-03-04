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

# Generate file DSL query from rules in routing.json
# Args: $1 = agent key
# Returns: file DSL string for file-query.awk
provider_rules_to_query() {
  local agent="$1"
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$routing_json")

  local parts=()

  # status_in — check if negative form is shorter
  local all_statuses status_in_count all_count
  all_statuses=$(jq -r '.statuses | length' "$routing_json")
  status_in_count=$(echo "$rules" | jq -r '.status_in | length')

  if (( status_in_count == all_statuses )); then
    : # all statuses — no filter needed
  elif (( all_statuses - status_in_count < status_in_count )); then
    # Negative form is shorter
    local excluded
    excluded=$(jq -r --argjson inc "$(echo "$rules" | jq '.status_in')" \
      '[.statuses[] | select(. as $s | $inc | index($s) | not)] | join(",")' "$routing_json")
    parts+=("!status:$excluded")
  else
    local included
    included=$(echo "$rules" | jq -r '.status_in | join(",")')
    parts+=("status:$included")
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
    empty_or_todo_or_label_needs_planning)
      parts+=('description:empty' 'label:needs-planning')
      # Note: these become OR conditions when combined with init_condition below,
      # but for file DSL, description:empty in planner means "match empty/TODO desc"
      # The OR is handled by the (file:needs-init OR (...)) wrapper
      # For standalone use, this means "description empty OR label needs-planning"
      # We need to use the OR group syntax
      parts=() # Reset — build as OR group below
      ;;
    not_empty_and_not_todo) parts+=('!description:empty') ;;
  esac

  # exclude_blocked
  local exclude_blocked
  exclude_blocked=$(echo "$rules" | jq -r '.exclude_blocked // false')
  if [[ "$exclude_blocked" == "true" ]]; then
    parts+=('!blocked')
  fi

  # init_condition — wraps everything in OR group with file:needs-init
  local init_cond
  init_cond=$(echo "$rules" | jq -r '.init_condition // "null"')

  if [[ "$init_cond" == "file_needs_init" ]]; then
    # Special planner query: (file:needs-init OR (status:... (description:empty OR label:needs-planning) !label:...))
    # Rebuild the inner part manually for the OR group
    local inner_parts=()

    # status_in
    if (( status_in_count < all_statuses )); then
      local inner_included
      inner_included=$(echo "$rules" | jq -r '.status_in | join(",")')
      inner_parts+=("status:$inner_included")
    fi

    # description condition for planner
    if [[ "$desc_cond" == "empty_or_todo_or_label_needs_planning" ]]; then
      inner_parts+=('(description:empty OR label:needs-planning)')
    fi

    # labels_exclude
    if [[ "$labels_exclude" != "null" ]]; then
      local inner_exc_list
      inner_exc_list=$(echo "$rules" | jq -r '.labels_exclude | join(",")')
      inner_parts+=("!label:$inner_exc_list")
    fi

    local inner_query="${inner_parts[*]}"
    echo "(file:needs-init OR ($inner_query))"
    return
  fi

  echo "${parts[*]}"
}
