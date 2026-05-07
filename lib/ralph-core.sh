#!/bin/zsh
# ralph-core.sh — Shared functions for Ralph agent ecosystem
#
# Sources sub-modules so existing `source ralph-core.sh` callers work unchanged.

# ─── Sub-modules ─────────────────────────────────────────────────────────────

_ralph_lib_dir="${0:A:h}"
[[ -z "$_ralph_lib_dir" || ! -d "$_ralph_lib_dir" ]] && _ralph_lib_dir="$RALPH_HOME/lib"

source "$_ralph_lib_dir/ralph-llm.sh"
source "$_ralph_lib_dir/ralph-worktree.sh"
source "$_ralph_lib_dir/ralph-titlebar.sh"
source "$_ralph_lib_dir/ralph-session.sh"
source "$_ralph_lib_dir/ralph-reflect.sh"
source "$_ralph_lib_dir/ralph-scratch.sh"

# ─── Init ─────────────────────────────────────────────────────────────────────

ralph_init() {
  # Resolve RALPH_HOME via realpath (works through npm symlinks)
  if [[ -z "$RALPH_HOME" ]]; then
    RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
  fi
  export RALPH_HOME

  # Load .ralphrc from CWD if present
  if [[ -f ".ralphrc" ]]; then
    source ".ralphrc"
  fi

  # Default provider
  export RALPH_PROVIDER="${RALPH_PROVIDER:-jira}"

  # Default model provider (LLM CLI)
  export RALPH_MODEL_PROVIDER="${RALPH_MODEL_PROVIDER:-claude}"

  case "$RALPH_MODEL_PROVIDER" in
    claude|gemini|codex) ;;
    *)
      ralph_error "Unknown RALPH_MODEL_PROVIDER: $RALPH_MODEL_PROVIDER (expected: claude, gemini, codex)"
      exit 1
      ;;
  esac
}

# ─── Logging ──────────────────────────────────────────────────────────────────

ralph_log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

ralph_error() {
  echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# ─── Environment ──────────────────────────────────────────────────────────────

ralph_validate_env() {
  local var
  for var in "$@"; do
    if [[ -z "${(P)var}" ]]; then
      ralph_error "$var is not set"
      exit 1
    fi
  done
}

# ─── Paths ────────────────────────────────────────────────────────────────────

ralph_get_prompt() {
  local agent="$1"
  echo "$RALPH_HOME/prompts/$agent.md"
}

ralph_get_provider_instructions() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/instructions.md"
}

ralph_get_routing_json() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/routing.json"
}

# ─── Provider ─────────────────────────────────────────────────────────────────

ralph_load_provider() {
  local provider_script="$RALPH_HOME/lib/providers/$RALPH_PROVIDER.sh"
  if [[ ! -f "$provider_script" ]]; then
    ralph_error "Provider not found: $RALPH_PROVIDER (expected $provider_script)"
    exit 1
  fi
  source "$provider_script"

  # Validate provider interface
  local required=(provider_fetch_tasks provider_check_tasks provider_check_blockers
                  provider_get_unresolved_blocker_keys
                  provider_render_kb provider_write_kb provider_rules_to_query)
  local func
  for func in "${required[@]}"; do
    if ! typeset -f "$func" > /dev/null 2>&1; then
      ralph_error "Provider '$RALPH_PROVIDER' missing required function: $func"
      exit 1
    fi
  done

  # Validate PROVIDER_ENV_VARS is set
  if [[ -z "${PROVIDER_ENV_VARS+x}" ]]; then
    ralph_error "Provider '$RALPH_PROVIDER' must define PROVIDER_ENV_VARS array"
    exit 1
  fi

  # Validate routing.json schema
  ralph_validate_routing_schema
}

# ─── Routing Schema Validation ────────────────────────────────────────────────

ralph_validate_routing_schema() {
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  [[ ! -f "$routing_json" ]] && return  # no routing.json = nothing to validate

  local errors
  errors=$(jq -r '
    def check:
      # Top-level keys
      (if .statuses | type != "array" then "statuses must be an array" else empty end),
      (if .labels | type != "array" then "labels must be an array" else empty end),
      (if .agents | type != "object" then "agents must be an object" else empty end),

      # Per-agent rules
      (.statuses as $statuses | .labels as $labels |
       .agents | to_entries[] |
       .key as $agent | .value.rules // empty |

       # status_in must be array with values in statuses
       (if .status_in | type != "array" then "\($agent): rules.status_in must be an array"
        else (.status_in[] | select(. as $s | $statuses | index($s) | not) |
              "\($agent): unknown status \"\(.)\" in status_in") end),

       # labels_include values in labels (if present)
       (if .labels_include != null and (.labels_include | type == "array") then
          .labels_include[] | select(. as $l | $labels | index($l) | not) |
          "\($agent): unknown label \"\(.)\" in labels_include"
        else empty end),

       # labels_exclude values in labels (if present)
       (if .labels_exclude != null and (.labels_exclude | type == "array") then
          .labels_exclude[] | select(. as $l | $labels | index($l) | not) |
          "\($agent): unknown label \"\(.)\" in labels_exclude"
        else empty end),

       # description_condition known enum
       (if .description_condition != null then
          .description_condition |
          select(. != "empty_or_todo_or_label_needs_planning" and . != "not_empty_and_not_todo") |
          "\($agent): unknown description_condition \"\(.)\""
        else empty end),

       # blocker_check known enum
       (if .blocker_check != null then
          .blocker_check |
          select(. != "done" and . != "no_needs_planning") |
          "\($agent): unknown blocker_check \"\(.)\""
        else empty end),

       # order_by known enum
       (if .order_by != null then
          .order_by |
          select(. != "priority_desc" and . != "created_desc" and . != "updated_desc") |
          "\($agent): unknown order_by \"\(.)\""
        else empty end)
      );
    check
  ' "$routing_json" 2>/dev/null)

  if [[ -n "$errors" ]]; then
    ralph_error "Routing schema errors in $routing_json:"
    echo "$errors" | while IFS= read -r line; do
      ralph_error "  $line"
    done
    exit 1
  fi
}

# ─── Unified Query Builder ───────────────────────────────────────────────────

# ralph_rules_to_dsl <agent>
# Reads routing.json rules for the given agent and emits a canonical DSL string.
# Tokens: assignee:me state:X,Y !state:X,Y label:X !label:X !description:empty !blocked
# Providers with native query languages (Jira/JQL) keep their own provider_rules_to_query.
# Providers using DSL (linear, github-issues, github-projects, file) delegate here.
ralph_rules_to_dsl() {
  local agent="$1"
  local routing_json
  routing_json="$(ralph_get_routing_json)"
  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$routing_json")

  local parts=()

  # status_in — check if negative form is shorter
  local all_statuses status_in_count
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
  esac

  # exclude_blocked
  local exclude_blocked
  exclude_blocked=$(echo "$rules" | jq -r '.exclude_blocked // false')
  if [[ "$exclude_blocked" == "true" ]]; then
    parts+=('!blocked')
  fi

  echo "${parts[*]}"
}

# ─── Queries ──────────────────────────────────────────────────────────────────

ralph_get_query() {
  local agent="$1"
  # Generate query from rules via the provider's rules_to_query function.
  # The provider must be sourced before calling this (see ralph-gated-loop.sh).
  provider_rules_to_query "$agent"
}

# ─── Config ───────────────────────────────────────────────────────────────────

ralph_get_poll_interval() {
  echo "${RALPH_POLL_INTERVAL:-15}"
}

# ralph_cooldown <seconds> <title_prefix>
# Counts down in the titlebar, sleeping 1s at a time.
# Respects $shutdown and $child_pid for clean signal handling.
ralph_cooldown() {
  local remaining="$1" prefix="$2"
  while (( remaining > 0 )); do
    ralph_titlebar_update "$prefix | Next poll: ${remaining}s"
    sleep 1 &
    child_pid=$!
    wait $child_pid 2>/dev/null || true
    child_pid=""
    [[ $shutdown -eq 1 ]] && return 1
    remaining=$((remaining - 1))
  done
}
