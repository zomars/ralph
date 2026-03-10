#!/bin/zsh
# github-projects.sh — GitHub Projects v2 provider for Ralph
#
# Uses GitHub Projects v2 board columns (Status field) for statuses.
# Labels are still managed on the underlying issues.
# Requires `gh` CLI for API access — no custom MCP server needed.
#
# Implements the provider contract:
#   PROVIDER_ENV_VARS  — Required environment variables
#   provider_check_tasks(query) — Returns task count for a given query
#   provider_rules_to_query(agent) — Generates DSL query from routing.json rules

# Required env vars for this provider
PROVIDER_ENV_VARS=(GITHUB_REPO GITHUB_PROJECT_NUMBER)

# No MCP server — agents use `gh` CLI via Bash tool
# PROVIDER_MCP_NAME and PROVIDER_MCP_CMD intentionally unset

# Check if tasks exist for the given query
# Args: $1 = DSL query string (e.g. "assignee:@me status:Todo,In+Progress !label:needs-input")
# Returns: task count (0 = no tasks)
provider_check_tasks() {
  local query="$1"

  # Parse DSL tokens
  local statuses=() label_excludes=() label_includes=()
  local has_assignee=false check_desc_not_empty=false

  local token
  for token in ${(z)query}; do
    case "$token" in
      assignee:@me)
        has_assignee=true
        ;;
      status:*)
        local values="${token#status:}"
        for s in ${(s:,:)values}; do
          # Restore spaces from + encoding
          statuses+=("${s//+/ }")
        done
        ;;
      !status:*)
        # Negative status — we'll invert in the jq filter
        local values="${token#!status:}"
        for s in ${(s:,:)values}; do
          statuses+=("!${s//+/ }")
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
      !description:empty)
        check_desc_not_empty=true
        ;;
      description:empty|!blocked)
        # Informational or handled elsewhere
        ;;
      *)
        ralph_error "Unknown DSL token: $token"
        ;;
    esac
  done

  # Derive owner and repo name from GITHUB_REPO (format: owner/repo)
  local owner="${GITHUB_REPO%%/*}"
  local repo="${GITHUB_REPO##*/}"

  # Query project items via GraphQL
  local gql_query
  gql_query=$(cat <<'GQL'
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      items(first: 100) {
        nodes {
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          content {
            ... on Issue {
              number
              state
              body
              assignees(first: 10) { nodes { login } }
              labels(first: 20) { nodes { name } }
            }
          }
        }
      }
    }
  }
}
GQL
)

  # Try user first, fall back to organization
  local response
  if ! response=$(gh api graphql \
    -f query="$gql_query" \
    -f owner="$owner" \
    -F number="$GITHUB_PROJECT_NUMBER" 2>&1); then
    # Try as organization
    gql_query="${gql_query//user(login: \$owner)/organization(login: \$owner)}"
    if ! response=$(gh api graphql \
      -f query="$gql_query" \
      -f owner="$owner" \
      -F number="$GITHUB_PROJECT_NUMBER" 2>&1); then
      ralph_error "Provider check failed: $response"
      echo "0"
      return 0
    fi
  fi

  # Get current user login for assignee filtering
  local me=""
  if $has_assignee; then
    me=$(gh api user --jq '.login' 2>/dev/null) || true
  fi

  # Build jq filter from parsed tokens
  local jq_filter='.data.user.projectV2.items.nodes // .data.organization.projectV2.items.nodes // []'
  jq_filter="$jq_filter | map(select(.content != null and .content.state == \"OPEN\"))"

  # Status filter
  if [[ ${#statuses[@]} -gt 0 ]]; then
    local first="${statuses[1]}"
    if [[ "$first" == !* ]]; then
      # Negative statuses
      local status_array
      status_array=$(printf '%s\n' "${statuses[@]}" | sed 's/^!//' | jq -R . | jq -sc .)
      jq_filter="$jq_filter | map(select(.fieldValueByName.name as \$s | ($status_array | index(\$s) | not)))"
    else
      local status_array
      status_array=$(printf '%s\n' "${statuses[@]}" | jq -R . | jq -sc .)
      jq_filter="$jq_filter | map(select(.fieldValueByName.name as \$s | ($status_array | index(\$s))))"
    fi
  fi

  # Assignee filter
  if $has_assignee && [[ -n "$me" ]]; then
    jq_filter="$jq_filter | map(select(.content.assignees.nodes | map(.login) | index(\"$me\")))"
  fi

  # Label include filter
  for l in "${label_includes[@]}"; do
    jq_filter="$jq_filter | map(select(.content.labels.nodes | map(.name) | index(\"$l\")))"
  done

  # Label exclude filter
  for l in "${label_excludes[@]}"; do
    jq_filter="$jq_filter | map(select(.content.labels.nodes | map(.name) | index(\"$l\") | not))"
  done

  # Description filter
  if $check_desc_not_empty; then
    jq_filter="$jq_filter | map(select(.content.body != null and .content.body != \"\" and (.content.body | test(\"^TODO\"; \"i\") | not)))"
  fi

  jq_filter="$jq_filter | length"

  echo "$response" | jq "$jq_filter"
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
      '[.statuses[] | select(. as $s | $inc | index($s) | not)] | map(gsub(" "; "+")) | join(",")' "$routing_json")
    parts+=("!status:$excluded")
  else
    local included
    included=$(echo "$rules" | jq -r '.status_in | map(gsub(" "; "+")) | join(",")')
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
    # empty_or_todo_or_label_needs_planning — not directly filterable
  esac

  # exclude_blocked — no-op, handled by ralph-blocked label in labels_exclude

  echo "${parts[*]}"
}
