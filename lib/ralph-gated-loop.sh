#!/bin/zsh
# ralph-gated-loop.sh — Backlog-gated AFK loop (thin wrapper over ralph-loop.sh)
#
# Usage: source this file, then call ralph_gated_loop <agent_key> <agent_name>

source "$RALPH_HOME/lib/ralph-loop.sh"

ralph_gated_loop_once() {
  ralph_gated_loop "$1" "$2" 1
}

ralph_gated_loop() {
  local _agent_key="$1"
  local _agent_name="$2"
  local _max_iterations="${3:-0}"

  # Temp file for single-task data (used by pick/render)
  local _task_file="/tmp/ralph-${_agent_key}-$$-task.json"

  # ─── Callbacks ──────────────────────────────────────────────────────────

  loop_init() {
    ralph_load_provider
  }

  loop_uses_worktree() {
    # Note: jq's `//` treats `false` as falsy, so we can't use it for boolean defaults.
    jq -r ".agents.${_agent_key}.rules | if has(\"uses_worktree\") then .uses_worktree else true end" \
      "$(ralph_get_routing_json)"
  }

  loop_fetch_work() {
    local query
    query="$(ralph_get_query "$_agent_key")"
    provider_fetch_tasks "$query" 10 > "$LOOP_WORK_FILE"
  }

  loop_count_work() {
    jq '.issues | length' "$LOOP_WORK_FILE"
  }

  # Traverse blocker chain to find the deepest unblocked blocker that matches
  # the agent's query. Returns 0 and writes the blocker to $_task_file if found.
  # Args: $1 = issue file, $2 = blocker_check mode, $3 = agent query
  #        $4 = visited keys (colon-separated, for cycle detection)
  _traverse_blockers() {
    local issue_file="$1" mode="$2" query="$3" visited="$4"
    local blocker_keys
    blocker_keys=$(provider_get_unresolved_blocker_keys "$issue_file" "$mode")
    [[ -z "$blocker_keys" ]] && return 1

    local tmp_blocker
    tmp_blocker=$(mktemp)
    for bk in ${=blocker_keys}; do
      # Cycle detection
      [[ ":$visited:" == *":$bk:"* ]] && continue

      # Fetch this blocker with the agent's query to check if it matches
      # Strip ORDER BY clause before wrapping in parens (JQL syntax)
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
        # Check if this blocker is itself blocked — if so, recurse deeper
        if ! provider_check_blockers "$tmp_blocker" "$mode"; then
          if _traverse_blockers "$tmp_blocker" "$mode" "$query" "$visited:$bk"; then
            rm -f "$tmp_blocker"
            return 0  # deeper blocker was picked into $_task_file
          fi
        fi
        # This blocker is unblocked (or its blockers don't match) — pick it
        cp "$tmp_blocker" "$_task_file"
        rm -f "$tmp_blocker"
        return 0
      fi
      rm -f "$tmp_result"
    done
    rm -f "$tmp_blocker"
    return 1
  }

  loop_pick_work() {
    # instance_num is set by ralph_run_loop in the parent scope (zsh dynamic scoping)
    local task_count
    task_count=$(loop_count_work)
    local _exclude_blocked
    _exclude_blocked=$(jq -r ".agents.${_agent_key}.rules.exclude_blocked // false" "$(ralph_get_routing_json)")
    local _blocker_check
    _blocker_check=$(jq -r ".agents.${_agent_key}.rules.blocker_check // \"done\"" "$(ralph_get_routing_json)")
    local _gate_label
    _gate_label=$(jq -r ".agents.${_agent_key}.rules.gate_label // \"\"" "$(ralph_get_routing_json)")
    local _query
    _query="$(ralph_get_query "$_agent_key")"
    local _skip_open_subtasks
    _skip_open_subtasks=$(jq -r ".agents.${_agent_key}.rules.skip_with_open_subtasks // false" "$(ralph_get_routing_json)")
    local unblocked_seen=0 pick_idx=0 _open_subtask_count has_gate
    while (( pick_idx < task_count )); do
      jq ".issues[$pick_idx]" "$LOOP_WORK_FILE" > "$_task_file"
      # Skip parent issues with incomplete subtasks — work the subtasks instead
      if [[ "$_skip_open_subtasks" == "true" ]]; then
        _open_subtask_count=$(jq '[.fields.subtasks[]? | select(.fields.status.statusCategory.key != "done")] | length' "$_task_file")
        if (( _open_subtask_count > 0 )); then
          ralph_log "Skipping $(jq -r '.key' "$_task_file") (has $_open_subtask_count open subtask(s))"
          pick_idx=$((pick_idx + 1))
          continue
        fi
      fi
      # Gate label check: skip tasks with gate_label that are still blocked
      # (code already reviewed in a prior iteration — wait for blockers to resolve)
      if [[ -n "$_gate_label" ]]; then
        has_gate=$(jq -r --arg gl "$_gate_label" \
          '[.fields.labels[]? | if type == "object" then .name else . end] | index($gl) != null' "$_task_file")
        if [[ "$has_gate" == "true" ]] && ! provider_check_blockers "$_task_file" "$_blocker_check"; then
          ralph_log "Skipping $(jq -r '.key' "$_task_file") (${_gate_label} but still blocked)"
          pick_idx=$((pick_idx + 1))
          continue
        fi
      fi
      if [[ "$_exclude_blocked" != "true" ]] || provider_check_blockers "$_task_file" "$_blocker_check"; then
        unblocked_seen=$((unblocked_seen + 1))
        if (( unblocked_seen == instance_num )); then
          LOOP_TASK_KEY=$(jq -r '.key' "$_task_file")
          LOOP_TASK_DISPLAY="Task: $LOOP_TASK_KEY"
          return 0
        fi
      else
        local blocked_key
        blocked_key=$(jq -r '.key' "$_task_file")
        # Traverse blocker chain — pick the deepest unblocked blocker that matches
        if _traverse_blockers "$_task_file" "$_blocker_check" "$_query" "$blocked_key"; then
          unblocked_seen=$((unblocked_seen + 1))
          if (( unblocked_seen == instance_num )); then
            LOOP_TASK_KEY=$(jq -r '.key' "$_task_file")
            ralph_log "Traversed blockers: $blocked_key → $LOOP_TASK_KEY"
            LOOP_TASK_DISPLAY="Task: $LOOP_TASK_KEY (unblocks $blocked_key)"
            return 0
          fi
        else
          local bkeys
          bkeys=$(provider_get_unresolved_blocker_keys "$_task_file" "$_blocker_check")
          ralph_log "Skipping $blocked_key (blocked by ${bkeys:-unknown}, not in this agent's scope)"
        fi
      fi
      pick_idx=$((pick_idx + 1))
    done
    return 1
  }

  loop_build_context() {
    local task_kb worktree_context=""
    task_kb=$(provider_render_kb "$_task_file")

    if [[ -n "${RALPH_WORKTREE_CONTEXT:-}" ]]; then
      worktree_context="
Worktree setup output (use this for ports, domains, and dev environment details):
$RALPH_WORKTREE_CONTEXT"
    fi
    # Detect the repo's actual default branch — claude --print injects its own
    # "Main branch" heuristic which can be wrong (e.g. says "main" when it's "develop").
    local default_branch
    default_branch=$(git -C "$work_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || default_branch=""
    local branch_override=""
    if [[ -n "$default_branch" ]]; then
      branch_override="
The repository default branch is \`$default_branch\` (NOT \`main\` unless that matches). Use \`origin/$default_branch\` when creating feature branches."
    fi
    echo "You are RALPH_${(U)_agent_key}, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir).${branch_override}

$task_kb

Execute your workflow now. Start with Step 1.${worktree_context}"
  }

  loop_post_iteration() {
    # For agents using a git worktree, reset to the default branch so the next
    # iteration starts clean. Skip for non-worktree agents (e.g. verifier).
    if [[ "$(loop_uses_worktree)" == "true" ]]; then
      local workspace_branch="ralph-workspace/${_agent_key}-${instance_num}"
      local default_ref="origin/HEAD"
      git -C "$work_dir" fetch origin --quiet 2>/dev/null || true
      git -C "$work_dir" checkout "$workspace_branch" 2>/dev/null || true
      git -C "$work_dir" reset --hard "$default_ref" 2>/dev/null \
        || git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
      git -C "$work_dir" clean -fd 2>/dev/null || true
    fi
    rm -f "$_task_file" 2>/dev/null
  }

  # ─── Run ────────────────────────────────────────────────────────────────

  ralph_run_loop "$_agent_key" "$_agent_name" "$_max_iterations"
}
