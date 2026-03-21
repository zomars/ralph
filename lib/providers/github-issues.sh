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

# Fetch full task data (stub — returns minimal structure for gated-loop)
provider_fetch_tasks() {
  local query="$1"
  local max_results="${2:-10}"
  # Re-use check logic but return issue numbers as minimal structure
  # GitHub Issues provider relies on Claude using gh CLI directly
  ralph_error "provider_fetch_tasks not fully implemented for github-issues"
  echo '{"issues":[]}'
  return 1
}

# No native blocking in GitHub Issues — always unblocked
provider_get_unresolved_blocker_keys() { echo ""; }
provider_check_blockers() { return 0; }

# Stub KB writer for GitHub Issues
# Args: $1 = path to JSON file (normalized format), $2 = KB directory path
provider_write_kb() {
  local issue_file="$1"
  local kb_dir="$2"
  echo "(GitHub Issues KB not implemented — agent will query directly)" > "$kb_dir/task.md"
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

# Generate DSL query from rules in routing.json
# Args: $1 = agent key
# Returns: DSL string for provider_check_tasks()
provider_rules_to_query() {
  local agent="$1"
  echo "assignee:@me $(ralph_rules_to_dsl "$agent")"
}
