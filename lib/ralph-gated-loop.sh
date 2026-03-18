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

  loop_fetch_work() {
    local query
    query="$(ralph_get_query "$_agent_key")"
    provider_fetch_tasks "$query" 10 > "$LOOP_WORK_FILE"
  }

  loop_count_work() {
    jq '.issues | length' "$LOOP_WORK_FILE"
  }

  loop_pick_work() {
    # instance_num is set by ralph_run_loop in the parent scope (zsh dynamic scoping)
    local task_count
    task_count=$(loop_count_work)
    local _blocker_check
    _blocker_check=$(jq -r ".agents.${_agent_key}.rules.blocker_check // \"done\"" "$(ralph_get_routing_json)")
    local unblocked_seen=0 pick_idx=0
    while (( pick_idx < task_count )); do
      jq ".issues[$pick_idx]" "$LOOP_WORK_FILE" > "$_task_file"
      if provider_check_blockers "$_task_file" "$_blocker_check"; then
        unblocked_seen=$((unblocked_seen + 1))
        if (( unblocked_seen == instance_num )); then
          LOOP_TASK_KEY=$(jq -r '.key' "$_task_file")
          LOOP_TASK_DISPLAY="Task: $LOOP_TASK_KEY"
          return 0
        fi
      else
        ralph_log "Skipping $(jq -r '.key' "$_task_file") (blocked)"
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
    echo "You are RALPH_${(U)_agent_key}, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir).

$task_kb

Execute your workflow now. Start with Step 1.${worktree_context}"
  }

  loop_post_iteration() {
    # Reset worktree to the repo's default branch (e.g. develop, main)
    # so the next iteration starts from a clean, up-to-date base.
    local workspace_branch="ralph-workspace/${_agent_key}-${instance_num}"
    local default_ref="origin/HEAD"
    git -C "$work_dir" fetch origin --quiet 2>/dev/null || true
    git -C "$work_dir" checkout "$workspace_branch" 2>/dev/null || true
    git -C "$work_dir" reset --hard "$default_ref" 2>/dev/null \
      || git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
    git -C "$work_dir" clean -fd 2>/dev/null || true
    rm -f "$_task_file" 2>/dev/null
  }

  # ─── Run ────────────────────────────────────────────────────────────────

  ralph_run_loop "$_agent_key" "$_agent_name" "$_max_iterations"
}
