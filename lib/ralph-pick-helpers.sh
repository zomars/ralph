#!/bin/zsh
# ralph-pick-helpers.sh — Sourceable helpers used by ralph-gated-loop.sh.
#
# Extracted from the loop closure so tests can exercise them directly.
# Depends on the active provider exposing:
#   provider_fetch_tasks <jql> <max>            — writes search JSON to stdout
#   provider_get_unresolved_blocker_keys <file> <mode> — echoes space-separated keys
#   provider_check_blockers <file> <mode>       — returns 0 if unblocked
# And on ralph_log being defined.

# Count incomplete subtasks on an issue. Echoes the count (0 if none / field absent).
_open_subtasks_of() {
  jq '[.fields.subtasks[]? | select(.fields.status.statusCategory.key != "done")] | length' "$1"
}

# Traverse blocker chain to find the deepest unblocked blocker that matches
# the agent's query. Returns 0 and writes the picked blocker to <dest_file>.
# Args: $1 = issue file (currently blocked)
#       $2 = blocker_check mode ("done" | "no_needs_planning" | ...)
#       $3 = agent query (JQL/Linear query; ORDER BY clause is stripped)
#       $4 = visited keys (colon-separated, for cycle detection)
#       $5 = skip_with_open_subtasks ("true"/"false")
#       $6 = destination file to copy the picked blocker into
_traverse_blockers() {
  local issue_file="$1" mode="$2" query="$3" visited="$4" skip_open_subtasks="$5" dest_file="$6"
  local blocker_keys
  blocker_keys=$(provider_get_unresolved_blocker_keys "$issue_file" "$mode")
  [[ -z "$blocker_keys" ]] && return 1

  local tmp_blocker
  tmp_blocker=$(mktemp)
  for bk in ${=blocker_keys}; do
    # Cycle detection
    [[ ":$visited:" == *":$bk:"* ]] && continue

    # Fetch this blocker with the agent's query to check if it matches.
    # Strip ORDER BY clause before wrapping in parens (JQL syntax).
    local base_query="${query%% ORDER BY *}"
    local bk_query="($base_query) AND key = \"$bk\""
    local tmp_result
    tmp_result=$(mktemp)
    provider_fetch_tasks "$bk_query" 1 > "$tmp_result"
    local match_count
    match_count=$(jq '.issues | length' "$tmp_result")

    if (( match_count > 0 )); then
      jq '.issues[0]' "$tmp_result" > "$tmp_blocker"
      rm -f "$tmp_result"
      # If this blocker is itself blocked, recurse deeper.
      if ! provider_check_blockers "$tmp_blocker" "$mode"; then
        if _traverse_blockers "$tmp_blocker" "$mode" "$query" "$visited:$bk" "$skip_open_subtasks" "$dest_file"; then
          rm -f "$tmp_blocker"
          return 0
        fi
      fi
      # Don't pick a parent whose subtasks are still open — its subtasks
      # are the real work and should be picked directly from the top-level queue.
      if [[ "$skip_open_subtasks" == "true" ]]; then
        local _osc
        _osc=$(_open_subtasks_of "$tmp_blocker")
        if (( _osc > 0 )); then
          ralph_log "Skipping blocker $bk (has $_osc open subtask(s))"
          continue
        fi
      fi
      cp "$tmp_blocker" "$dest_file"
      rm -f "$tmp_blocker"
      return 0
    fi
    rm -f "$tmp_result"
  done
  rm -f "$tmp_blocker"
  return 1
}
