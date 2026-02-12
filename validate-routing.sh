#!/bin/bash
set -eo pipefail

# Ralph Routing Validator
# Validates routing.json for overlaps, gaps, and drift from prompt files.
#
# Usage:
#   ./ralph/validate-routing.sh              # Default: simulate ticket states, report overlaps/gaps
#   ./ralph/validate-routing.sh --matrix     # Full matrix output
#   ./ralph/validate-routing.sh --check-prompts  # Check JQL drift between routing.json and prompt files

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_JSON="$SCRIPT_DIR/routing.json"

if [ ! -f "$ROUTING_JSON" ]; then
  echo "ERROR: routing.json not found at $ROUTING_JSON"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed"
  exit 1
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Get all agent keys
get_agents() {
  jq -r '.agents | keys[]' "$ROUTING_JSON"
}

# Check if an agent matches a given ticket state
# Args: agent_key, status, labels (comma-separated or "none"), description_state
agent_matches() {
  local agent="$1"
  local status="$2"
  local labels="$3"        # comma-separated list or "none"
  local desc_state="$4"    # "empty", "todo", "filled"

  local rules
  rules=$(jq -c ".agents.${agent}.rules" "$ROUTING_JSON")

  # Check status
  local status_match
  status_match=$(echo "$rules" | jq -r --arg s "$status" '.status_in | map(select(. == $s)) | length')
  if [ "$status_match" -eq 0 ]; then
    return 1
  fi

  # Check labels_include (if set, at least one must be present)
  local labels_include
  labels_include=$(echo "$rules" | jq -r '.labels_include // empty')
  if [ -n "$labels_include" ]; then
    local found=0
    local req_label
    while IFS= read -r req_label; do
      if echo ",$labels," | grep -q ",$req_label,"; then
        found=1
        break
      fi
    done < <(echo "$rules" | jq -r '.labels_include[]')
    if [ "$found" -eq 0 ]; then
      return 1
    fi
  fi

  # Check labels_exclude (if set, none may be present)
  local labels_exclude
  labels_exclude=$(echo "$rules" | jq -r '.labels_exclude // empty')
  if [ -n "$labels_exclude" ]; then
    local excl_label
    while IFS= read -r excl_label; do
      if echo ",$labels," | grep -q ",$excl_label,"; then
        return 1
      fi
    done < <(echo "$rules" | jq -r '.labels_exclude[]')
  fi

  # Check description_condition
  local desc_cond
  desc_cond=$(echo "$rules" | jq -r '.description_condition // "null"')

  case "$desc_cond" in
    "null"|"")
      # No condition — matches any description state
      ;;
    "empty_or_todo_or_label_needs_planning")
      # Matches if desc is empty, todo, OR ticket has needs-planning label
      local has_needs_planning=0
      if echo ",$labels," | grep -q ",needs-planning,"; then
        has_needs_planning=1
      fi
      if [ "$desc_state" != "empty" ] && [ "$desc_state" != "todo" ] && [ "$has_needs_planning" -eq 0 ]; then
        return 1
      fi
      ;;
    "not_empty_and_not_todo")
      if [ "$desc_state" = "empty" ] || [ "$desc_state" = "todo" ]; then
        return 1
      fi
      ;;
    *)
      echo "WARNING: Unknown description_condition: $desc_cond" >&2
      ;;
  esac

  return 0
}

# ─── Modes ───────────────────────────────────────────────────────────────────

run_simulation() {
  local show_matrix="${1:-false}"
  local desc_states=("empty" "todo" "filled")

  # Read statuses and labels into arrays (macOS-compatible)
  local statuses=()
  while IFS= read -r line; do statuses+=("$line"); done < <(jq -r '.statuses[]' "$ROUTING_JSON")

  local all_labels=()
  while IFS= read -r line; do all_labels+=("$line"); done < <(jq -r '.labels[]' "$ROUTING_JSON")

  # Generate label combinations:
  # - none (no labels)
  # - each single label
  # - a few realistic multi-label combos
  local label_combos=("none")
  for l in "${all_labels[@]}"; do
    label_combos+=("$l")
  done
  # Add realistic multi-label combos
  label_combos+=("needs-tests,needs-planning")
  label_combos+=("tech-debt,needs-planning")
  label_combos+=("needs-tests,tech-debt")
  label_combos+=("ralph-blocked,needs-planning")
  label_combos+=("needs-tests,ralph-blocked")
  label_combos+=("documented,tech-debt")

  local agents=()
  while IFS= read -r line; do agents+=("$line"); done < <(get_agents)

  local overlap_count=0
  local gap_count=0
  local total=0

  if [ "$show_matrix" = "true" ]; then
    printf "%-14s %-30s %-8s |" "STATUS" "LABELS" "DESC"
    for agent in "${agents[@]}"; do
      printf " %-4s" "${agent:0:4}"
    done
    printf " | RESULT\n"
    printf '%120s\n' '' | tr ' ' '-'
  fi

  for status in "${statuses[@]}"; do
    for labels in "${label_combos[@]}"; do
      for desc in "${desc_states[@]}"; do
        total=$((total + 1))
        local matches=()

        for agent in "${agents[@]}"; do
          if agent_matches "$agent" "$status" "$labels" "$desc"; then
            matches+=("$agent")
          fi
        done

        local match_count=${#matches[@]}
        local result=""

        if [ "$match_count" -eq 0 ]; then
          result="GAP"
          gap_count=$((gap_count + 1))
        elif [ "$match_count" -eq 1 ]; then
          result="ok (${matches[0]})"
        else
          result="OVERLAP: ${matches[*]}"
          overlap_count=$((overlap_count + 1))
        fi

        if [ "$show_matrix" = "true" ]; then
          printf "%-14s %-30s %-8s |" "$status" "$labels" "$desc"
          for agent in "${agents[@]}"; do
            local mark=" . "
            for m in "${matches[@]}"; do
              if [ "$m" = "$agent" ]; then
                mark=" X "
                break
              fi
            done
            printf " %-4s" "$mark"
          done
          printf " | %s\n" "$result"
        elif [ "$match_count" -ne 1 ]; then
          # In default mode, only print problems
          printf "%-14s %-30s %-8s -> %s\n" "$status" "$labels" "$desc" "$result"
        fi
      done
    done
  done

  echo ""
  echo "=== Summary ==="
  echo "Total states simulated: $total"
  echo "Overlaps: $overlap_count"
  echo "Gaps: $gap_count"

  if [ "$overlap_count" -gt 0 ]; then
    echo ""
    echo "FAIL: $overlap_count overlap(s) found. Multiple agents would claim the same ticket."
    return 1
  fi

  if [ "$gap_count" -gt 0 ]; then
    echo ""
    echo "INFO: $gap_count gap(s) found. Some ticket states have no agent assigned."
    echo "(Gaps may be intentional — e.g., tickets in 'In Review' with 'needs-planning' label.)"
  fi

  echo ""
  echo "PASS: No overlaps detected."
  return 0
}

check_prompts() {
  local exit_code=0

  echo "Checking JQL drift between routing.json and prompt files..."
  echo ""

  local agent
  for agent in $(get_agents); do
    local json_jql
    local prompt_file
    json_jql=$(jq -r ".agents.${agent}.jql" "$ROUTING_JSON")
    prompt_file=$(jq -r ".agents.${agent}.prompt" "$ROUTING_JSON")

    local full_prompt_path="$SCRIPT_DIR/../$prompt_file"
    if [ ! -f "$full_prompt_path" ]; then
      echo "WARNING: Prompt file not found: $prompt_file"
      exit_code=1
      continue
    fi

    # Extract JQL from prompt markdown
    # Pattern 1: **JQL**: `...` (on same line)
    local prompt_jql=""
    prompt_jql=$(sed -n 's/.*\*\*JQL\*\*: `\(.*\)`$/\1/p' "$full_prompt_path" 2>/dev/null | head -1 || true)

    if [ -z "$prompt_jql" ]; then
      # Pattern 2: line after "**JQL**" header, indented with backticks
      prompt_jql=$(sed -n '/\*\*JQL\*\*/{n;p;}' "$full_prompt_path" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | sed 's/`//g' || true)
    fi

    if [ -z "$prompt_jql" ]; then
      # Pattern 3: "with JQL:" then backtick-wrapped JQL on next line
      prompt_jql=$(sed -n '/with JQL:/{n;p;}' "$full_prompt_path" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | sed 's/`//g' || true)
    fi

    if [ -z "$prompt_jql" ]; then
      # Pattern 4: any backtick-wrapped line containing "assignee = currentUser()"
      prompt_jql=$(grep 'assignee = currentUser()' "$full_prompt_path" 2>/dev/null | grep '`' | head -1 | sed 's/^[[:space:]]*//' | sed 's/`//g' || true)
    fi

    if [ -z "$prompt_jql" ]; then
      echo "WARNING: Could not extract JQL from $prompt_file for agent '$agent'"
      exit_code=1
      continue
    fi

    # Normalize: replace single quotes with double quotes for comparison
    local norm_json
    local norm_prompt
    norm_json=$(echo "$json_jql" | sed "s/'/\"/g")
    norm_prompt=$(echo "$prompt_jql" | sed "s/'/\"/g")

    if [ "$norm_json" = "$norm_prompt" ]; then
      echo "  $agent: OK"
    else
      echo "  $agent: DRIFT DETECTED"
      echo "    routing.json: $json_jql"
      echo "    $prompt_file: $prompt_jql"
      echo ""
      exit_code=1
    fi
  done

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    echo "PASS: No JQL drift detected."
  else
    echo "FAIL: JQL drift detected. Update routing.json or prompt files to match."
  fi

  return $exit_code
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --matrix)
    run_simulation true
    ;;
  --check-prompts)
    check_prompts
    ;;
  --help|-h)
    echo "Usage: $0 [--matrix | --check-prompts]"
    echo ""
    echo "  (default)        Simulate ticket states, report overlaps and gaps"
    echo "  --matrix         Full matrix output showing all agents vs all states"
    echo "  --check-prompts  Check JQL drift between routing.json and prompt files"
    exit 0
    ;;
  "")
    run_simulation false
    ;;
  *)
    echo "Unknown option: $1"
    echo "Usage: $0 [--matrix | --check-prompts]"
    exit 1
    ;;
esac
