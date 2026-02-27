#!/bin/zsh
# ralph-gated-loop.sh — Parameterized backlog-gated AFK loop
#
# Usage: source this file, then call ralph_gated_loop <agent_key> <agent_name>

ralph_claim_instance() {
  local agent_key="$1"
  local base_dir="/tmp/ralph-${agent_key}"
  mkdir -p "$base_dir"
  local i=1
  while true; do
    local slot="$base_dir/$i"
    if mkdir "$slot" 2>/dev/null; then
      echo $$ > "$slot/pid"
      echo "$i"
      return
    fi
    # Slot exists — check if holder is still alive
    if [[ -f "$slot/pid" ]] && ! kill -0 "$(cat "$slot/pid")" 2>/dev/null; then
      rm -rf "$slot"
      continue  # retry same slot
    fi
    i=$((i + 1))
  done
}

ralph_gated_loop_once() {
  ralph_gated_loop "$1" "$2" "true"
}

ralph_gated_loop() {
  local agent_key="$1"
  local agent_name="$2"
  local run_once="${3:-false}"

  # ─── Init ─────────────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-core.sh"
  ralph_init
  ralph_load_provider

  # ─── Instance slot ────────────────────────────────────────────────────────
  local instance_num instance_slot
  instance_num=$(ralph_claim_instance "$agent_key")
  instance_slot="/tmp/ralph-${agent_key}/${instance_num}"

  # ─── Session log ────────────────────────────────────────────────────────
  local session_log="$instance_slot/session.log"

  # ─── Worktree ───────────────────────────────────────────────────────────
  local project_dir="$PWD"
  local work_dir
  work_dir=$(ralph_setup_worktree "$agent_key" "$instance_num")

  # Validate provider-specific env vars
  ralph_validate_env $PROVIDER_ENV_VARS

  # Resolve paths
  local query prompt_file provider_instructions poll_interval
  query="$(ralph_get_query "$agent_key")"
  prompt_file="$(ralph_get_prompt "$agent_key")"
  provider_instructions="$(ralph_get_provider_instructions)"
  poll_interval="$(ralph_get_poll_interval)"

  if [[ ! -f "$prompt_file" ]]; then
    ralph_error "Prompt not found: $prompt_file"
    exit 1
  fi

  if [[ ! -f "$provider_instructions" ]]; then
    ralph_error "Provider instructions not found: $provider_instructions"
    exit 1
  fi

  # ─── jq filters ─────────────────────────────────────────────────────────
  ralph_get_jq_filters
  local stream_text="$RALPH_STREAM_FILTER"
  local final_result="$RALPH_RESULT_FILTER"

  # ─── State ──────────────────────────────────────────────────────────────
  local iteration=0
  local tmpfile=""
  local child_pid=""
  local shutdown=0

  trap 'shutdown=1; [[ -n "$child_pid" ]] && kill -INT -$child_pid 2>/dev/null' INT TERM HUP
  local last_task_key=""
  trap 'ralph_save_session_log "$session_log" "$agent_key" "$instance_num" "$last_task_key"; ralph_titlebar_cleanup; rm -f "$tmpfile" 2>/dev/null; rm -rf "$instance_slot" 2>/dev/null; ralph_cleanup_worktree "$work_dir"; [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null' EXIT

  die() {
    ralph_save_session_log "$session_log" "$agent_key" "$instance_num" "$last_task_key"
    ralph_titlebar_cleanup
    printf "\nShutting down.\n"
    rm -f "$tmpfile" 2>/dev/null
    tmpfile=""
    rm -rf "$instance_slot" 2>/dev/null
    ralph_cleanup_worktree "$work_dir"
    [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null
    exit 1
  }

  # ─── Early exit for --once with no work (before titlebar clears screen) ─
  if [[ "$run_once" == "true" ]]; then
    local early_count
    early_count=$(provider_check_tasks "$query")
    if [[ "$early_count" -lt "$instance_num" ]]; then
      ralph_log "${agent_name} #$instance_num: No tasks available ($early_count found). Nothing to do."
      rm -rf "$instance_slot" 2>/dev/null
      exit 0
    fi
  fi

  ralph_titlebar_init

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    local task_count
    task_count=$(provider_check_tasks "$query")

    if [[ "$task_count" -lt "$instance_num" ]]; then
      if [[ "$run_once" == "true" ]]; then
        ralph_log "${agent_name} #$instance_num: No tasks available ($task_count found). Nothing to do."
        exit 0
      fi
      ralph_log "Not enough tasks for instance #$instance_num ($task_count available). Sleeping ${poll_interval}s..."
      ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | Waiting" || die
      continue
    fi

    iteration=$((iteration + 1))
    tmpfile=$(mktemp)

    ralph_titlebar_update "${(U)agent_name} #$instance_num | Iteration $iteration | Tasks: $task_count | $(date '+%H:%M:%S')"
    echo "------- ${(U)agent_name} #$instance_num ITERATION $iteration ($task_count tasks) --------"

    # Write iteration marker to session log
    echo '{"type":"_ralph_marker","iteration":'$iteration',"timestamp":"'$(date -Iseconds)'","tasks":'$task_count'}' >> "$session_log"

    local initial_message
    initial_message="You are RALPH_${(U)agent_key}, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir). Execute your workflow now. Start with Step 1."

    setopt MONITOR
    {
      (
        ralph_exec_llm "$agent_key" "$instance_num" "$work_dir" "$prompt_file" "$provider_instructions" "$initial_message" \
        | grep --line-buffered '^{' \
        | tee "$tmpfile" | tee -a "$session_log" \
        | jq --unbuffered -rj "$stream_text"
      ) </dev/null &
    } 2>/dev/null
    child_pid=$!
    unsetopt MONITOR
    wait $child_pid 2>/dev/null || true
    [[ $shutdown -eq 1 ]] && die
    kill -9 -$child_pid 2>/dev/null || true
    child_pid=""

    local result
    result=$(jq -r "$final_result" "$tmpfile")
    last_task_key=$(ralph_extract_task_key "$tmpfile")

    rm -f "$tmpfile"
    tmpfile=""

    if [[ "$result" == *"<promise>ABORT</promise>"* ]]; then
      echo "Ralph ($agent_name) aborted at iteration $iteration."
      exit 1
    fi

    if [[ "$run_once" == "true" ]]; then
      ralph_log "Iteration complete. Exiting (--once mode)."
      exit 0
    fi

    ralph_log "Iteration complete. Cooldown ${poll_interval}s..."
    ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | Cooldown" || die
  done
}
