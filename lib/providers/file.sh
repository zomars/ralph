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

# File provider doesn't support fetch (tasks are in the PRD file)
provider_fetch_tasks() {
  local query="$1"
  ralph_error "provider_fetch_tasks not implemented for file provider"
  echo '{"issues":[]}'
  return 1
}

# No blocking concept in file provider
provider_get_unresolved_blocker_keys() { echo ""; }
provider_check_blockers() { return 0; }

# Stub KB writer
# Args: $1 = path to JSON file (normalized format), $2 = KB directory path
provider_write_kb() {
  local issue_file="$1"
  local kb_dir="$2"
  echo "(File provider KB not implemented — agent reads PRD directly)" > "$kb_dir/task.md"
  echo "" > "$kb_dir/description.md"
  echo "" > "$kb_dir/comments.md"
  echo "[]" > "$kb_dir/links.json"
  echo "{}" > "$kb_dir/meta.json"
}

# Render issue data as inline markdown (stub)
# Args: $1 = path to JSON file (normalized format)
provider_render_kb() {
  local issue_file="$1"
  echo "# YOUR ASSIGNED TASK"
  echo ""
  echo "(Provider does not support inline KB rendering — agent will query directly)"
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

  # Check for init_condition — file provider special case
  local init_cond
  init_cond=$(echo "$rules" | jq -r '.init_condition // "null"')

  if [[ "$init_cond" == "file_needs_init" ]]; then
    # Special planner query: (file:needs-init OR (status:... (description:empty OR label:needs-planning) !label:...))
    local inner_parts=()

    local all_statuses status_in_count
    all_statuses=$(jq -r '.statuses | length' "$routing_json")
    status_in_count=$(echo "$rules" | jq -r '.status_in | length')

    if (( status_in_count < all_statuses )); then
      local inner_included
      inner_included=$(echo "$rules" | jq -r '.status_in | join(",")')
      inner_parts+=("status:$inner_included")
    fi

    local desc_cond
    desc_cond=$(echo "$rules" | jq -r '.description_condition // "null"')
    if [[ "$desc_cond" == "empty_or_todo_or_label_needs_planning" ]]; then
      inner_parts+=('(description:empty OR label:needs-planning)')
    fi

    local labels_exclude
    labels_exclude=$(echo "$rules" | jq -r '.labels_exclude // null')
    if [[ "$labels_exclude" != "null" ]]; then
      local inner_exc_list
      inner_exc_list=$(echo "$rules" | jq -r '.labels_exclude | join(",")')
      inner_parts+=("!label:$inner_exc_list")
    fi

    echo "(file:needs-init OR (${inner_parts[*]}))"
    return
  fi

  # Standard case — delegate to shared DSL builder
  ralph_rules_to_dsl "$agent"
}
