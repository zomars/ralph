#!/bin/zsh
# github-issues.sh — GitHub Issues provider for Ralph
#
# Uses GitHub issue labels as statuses (e.g. "status:to-do", "status:in-progress").
# Requires `gh` CLI for API access — no custom MCP server needed.
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query
#   provider_rules_to_query(agent) — Generates DSL query from routing.json rules

# Required env vars for this provider
PROVIDER_ENV_VARS=(GITHUB_REPO)

# No MCP server — agents use `gh` CLI via Bash tool
# PROVIDER_MCP_NAME and PROVIDER_MCP_CMD intentionally unset

# Check if tasks exist for the given query
# Args: $1 = DSL query string (e.g. "assignee:@me status:to-do,in-progress !label:needs-input")
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"

  # Parse DSL tokens into gh search arguments
  local statuses=() label_excludes=() label_includes=()
  local has_assignee=false

  local token
  for token in ${(z)query}; do
    case "$token" in
      assignee:@me)
        has_assignee=true
        ;;
      status:*)
        local values="${token#status:}"
        for s in ${(s:,:)values}; do
          statuses+=("$s")
        done
        ;;
      label:*)
        local values="${token#label:}"
        for l in ${(s:,:)values}; do
          label_includes+=("$l")
        done
        ;;
      !label:*)
        local values="${token#!label:}"
        for l in ${(s:,:)values}; do
          label_excludes+=("$l")
        done
        ;;
      !description:empty|description:empty|!blocked)
        # Handled as post-filters or informational
        ;;
      *)
        ralph_error "Unknown DSL token: $token"
        ;;
    esac
  done

  # Build search query for gh issue list --search
  # GitHub search uses OR for multiple label: terms in search string
  local search_parts=()
  if [[ ${#statuses[@]} -gt 0 ]]; then
    local status_search=""
    for s in "${statuses[@]}"; do
      if [[ -n "$status_search" ]]; then
        status_search="$status_search OR label:\"status:$s\""
      else
        status_search="label:\"status:$s\""
      fi
    done
    search_parts+=("($status_search)")
  fi

  for l in "${label_includes[@]}"; do
    search_parts+=("label:\"$l\"")
  done

  for l in "${label_excludes[@]}"; do
    search_parts+=("-label:\"$l\"")
  done

  local search_str="${(j: :)search_parts}"

  local assignee_flag=""
  if $has_assignee; then
    assignee_flag="--assignee @me"
  fi

  local result
  if ! result=$(eval "gh issue list --repo '$GITHUB_REPO' ${assignee_flag} --state open --search '$search_str' --json number --limit 100" 2>&1); then
    ralph_error "Provider check failed: $result"
    echo "0"
    return 0
  fi

  echo "$result" | jq 'length'
}

# Generate DSL query from rules in routing.json
# Args: $1 = agent key
# Returns: DSL string for provider_check_tasks()
provider_rules_to_query() {
  local agent="$1"
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$routing_json")

  local parts=()
  parts+=('assignee:@me')

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
    not_empty_and_not_todo) parts+=('!description:empty') ;;
    # empty_or_todo_or_label_needs_planning — not directly filterable via search
  esac

  # exclude_blocked — no-op, handled by ralph-blocked label in labels_exclude
  # (GitHub Issues doesn't have native blocking; use labels instead)

  echo "${parts[*]}"
}
