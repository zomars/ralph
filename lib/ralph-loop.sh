#!/bin/zsh
# ralph-loop.sh — Shared loop skeleton for all agent loops
#
# Callers define callbacks before invoking ralph_run_loop:
#   loop_init            — provider loading, auth checks, validation
#   loop_fetch_work      — fetch work items, write JSON to $LOOP_WORK_FILE
#   loop_count_work      — echo count of available items from $LOOP_WORK_FILE
#   loop_pick_work       — pick item for this instance, set LOOP_TASK_KEY and LOOP_TASK_DISPLAY
#   loop_build_context   — echo initial message string
#   loop_post_iteration  — optional cleanup (e.g. worktree reset)
#   loop_uses_worktree   — optional, echo "true" if worktree needed (default: true)
#   loop_no_work_label   — optional, echo label for "no work" messages (default: "tasks")

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
    if [[ ! -f "$slot/pid" ]] || ! kill -0 "$(cat "$slot/pid")" 2>/dev/null; then
      rm -rf "$slot"
      continue  # retry same slot
    fi
    i=$((i + 1))
  done
}

# ralph_run_loop <agent_key> <agent_name> [max_iterations]
ralph_run_loop() {
  local agent_key="$1"
  local agent_name="$2"
  local max_iterations="${3:-0}"  # 0 = unlimited

  # ─── Init ─────────────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-core.sh"
  ralph_init

  # Callback: provider/auth init
  loop_init

  # ─── Instance slot ────────────────────────────────────────────────────────
  local instance_num instance_slot
  instance_num=$(ralph_claim_instance "$agent_key")
  instance_slot="/tmp/ralph-${agent_key}/${instance_num}"

  # ─── Session log ────────────────────────────────────────────────────────
  local session_log="$instance_slot/session.log"

  # ─── Worktree ───────────────────────────────────────────────────────────
  local project_dir="$PWD"
  local work_dir uses_worktree
  uses_worktree=$(typeset -f loop_uses_worktree > /dev/null 2>&1 && loop_uses_worktree || echo "true")
  if [[ "$uses_worktree" == "true" ]]; then
    ralph_setup_worktree "$agent_key" "$instance_num"
    work_dir="$RALPH_WORKTREE_DIR"
  elif [[ "$uses_worktree" == "false" ]]; then
    if ! ralph_setup_verifier_cwd "$agent_key" "$instance_num"; then
      rm -rf "$instance_slot" 2>/dev/null
      exit 1
    fi
    work_dir="$RALPH_WORKTREE_DIR"
  else
    work_dir="$PWD"
  fi

  # Validate provider-specific env vars (if set)
  if [[ -n "${PROVIDER_ENV_VARS+x}" ]]; then
    ralph_validate_env $PROVIDER_ENV_VARS
  fi

  # Resolve paths
  local prompt_file provider_instructions poll_interval
  prompt_file="$(ralph_get_prompt "$agent_key")"
  provider_instructions="$(ralph_get_provider_instructions)"
  poll_interval="$(ralph_get_poll_interval)"

  if [[ ! -f "$prompt_file" ]]; then
    ralph_error "Prompt not found: $prompt_file"
    exit 1
  fi

  # ─── jq filters ─────────────────────────────────────────────────────────
  ralph_get_jq_filters
  local stream_text="$RALPH_STREAM_FILTER"
  local final_result="$RALPH_RESULT_FILTER"

  # ─── Model (for titlebar display) ──────────────────────────────────────
  local model_id model_short
  model_id=$(ralph_resolve_model "$agent_key")
  case "$model_id" in
    *opus*)   model_short="opus" ;;
    *sonnet*) model_short="sonnet" ;;
    *haiku*)  model_short="haiku" ;;
    *)        model_short="$model_id" ;;
  esac

  # ─── State ──────────────────────────────────────────────────────────────
  local iteration=0
  local tmpfile=""
  local child_pid=""
  local shutdown=0
  local consecutive_empty=0
  local max_consecutive_empty="${RALPH_MAX_EMPTY_ITERATIONS:-5}"
  local no_work_label
  no_work_label=$(typeset -f loop_no_work_label > /dev/null 2>&1 && loop_no_work_label || echo "tasks")

  local consecutive_same_task=0
  local max_consecutive_same="${RALPH_MAX_SAME_TASK:-3}"
  local prev_task_key=""

  trap 'shutdown=1; [[ -n "$child_pid" ]] && kill -INT -$child_pid 2>/dev/null' INT TERM HUP
  local last_task_key=""

  # Work data file
  LOOP_WORK_FILE="/tmp/ralph-${agent_key}-${instance_num}-work.json"

  _loop_die() {
    ralph_titlebar_cleanup
    printf "\nShutting down.\n"
    rm -f "$tmpfile" "$LOOP_WORK_FILE" 2>/dev/null
    tmpfile=""
    rm -rf "$instance_slot" 2>/dev/null
    [[ "$uses_worktree" == "true" ]] && ralph_cleanup_worktree "$work_dir"
    # Kill streaming pipeline by real PGID, then Claude
    [[ -n "$stream_pgid" ]] && kill -9 -$stream_pgid 2>/dev/null || true
    [[ -n "$stream_pid" ]] && kill -9 -$stream_pid 2>/dev/null || true
    [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null || true
    exit 1
  }

  trap 'ralph_titlebar_cleanup; rm -f "$tmpfile" "$LOOP_WORK_FILE" 2>/dev/null; rm -rf "$instance_slot" 2>/dev/null; [[ "$uses_worktree" == "true" ]] && ralph_cleanup_worktree "$work_dir"; [[ -n "$stream_pgid" ]] && kill -9 -$stream_pgid 2>/dev/null || true; [[ -n "$stream_pid" ]] && kill -9 -$stream_pid 2>/dev/null || true; [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null || true' EXIT

  # ─── Early exit for bounded runs with no work (before titlebar clears screen)
  local has_prefetch=0
  if [[ "$max_iterations" -gt 0 ]]; then
    loop_fetch_work
    has_prefetch=1
    local early_count
    early_count=$(loop_count_work)
    if [[ "$early_count" -lt "$instance_num" ]]; then
      ralph_log "${agent_name} #$instance_num: No $no_work_label available ($early_count found). Nothing to do."
      rm -rf "$instance_slot" 2>/dev/null
      exit 0
    fi
  fi

  ralph_titlebar_init

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    # Re-create worktree if it disappeared
    if [[ "$uses_worktree" == "true" && ! -d "$work_dir" ]]; then
      ralph_log "Worktree missing ($work_dir). Recreating..."
      ralph_setup_worktree "$agent_key" "$instance_num"
      work_dir="$RALPH_WORKTREE_DIR"
    fi

    # Fetch work (reuse prefetch on first iteration)
    if [[ "$has_prefetch" -eq 1 ]]; then
      has_prefetch=0
    else
      loop_fetch_work
    fi
    local work_count
    work_count=$(loop_count_work)

    if [[ "$work_count" -lt "$instance_num" ]]; then
      if [[ "$max_iterations" -gt 0 ]]; then
        ralph_log "${agent_name} #$instance_num: No $no_work_label available ($work_count found). Nothing to do."
        exit 0
      fi
      ralph_log "Not enough $no_work_label for instance #$instance_num ($work_count available). Sleeping ${poll_interval}s..."
      local wait_label="Iteration $iteration"
      [[ -n "$last_task_key" ]] && wait_label+=" | Last: $last_task_key"
      wait_label+=" | Waiting"
      ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | $model_short | $wait_label" || _loop_die
      continue
    fi

    # Pick work item for this instance
    LOOP_TASK_KEY=""
    LOOP_TASK_DISPLAY=""
    if ! loop_pick_work; then
      if [[ "$max_iterations" -gt 0 ]]; then
        ralph_log "${agent_name} #$instance_num: No eligible $no_work_label for this instance. Nothing to do."
        exit 0
      fi
      ralph_log "No eligible $no_work_label for instance #$instance_num. Sleeping ${poll_interval}s..."
      local wait_label2="Iteration $iteration"
      [[ -n "$last_task_key" ]] && wait_label2+=" | Last: $last_task_key"
      wait_label2+=" | Waiting"
      ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | $model_short | $wait_label2" || _loop_die
      continue
    fi

    # Same-task repeat guard: auto-block tasks stuck across iterations
    if [[ "$LOOP_TASK_KEY" == "$prev_task_key" ]]; then
      consecutive_same_task=$((consecutive_same_task + 1))
      if (( consecutive_same_task > max_consecutive_same )); then
        ralph_log "Task $LOOP_TASK_KEY stuck ($consecutive_same_task consecutive iterations). Auto-blocking."
        if typeset -f provider_mark_blocked > /dev/null 2>&1; then
          provider_mark_blocked "$LOOP_TASK_KEY" \
            "Loop guard: $max_consecutive_same consecutive iterations without completion"
        fi
        prev_task_key=""
        consecutive_same_task=0
        continue
      fi
    else
      prev_task_key="$LOOP_TASK_KEY"
      consecutive_same_task=1
    fi

    last_task_key="$LOOP_TASK_KEY"
    iteration=$((iteration + 1))
    tmpfile=$(mktemp)

    # Per-iteration archive — streamed live during the iteration so a kill -9
    # (OOM, panic) still leaves partial output on disk. Overwritten with the
    # canonical filtered output once the iteration completes.
    local iter_archive=""
    if [[ -n "${RALPH_LOG_DIR:-}" ]]; then
      local iter_log_dir="${RALPH_LOG_DIR%/}/${agent_key}-${instance_num}"
      mkdir -p "$iter_log_dir"
      local iter_suffix="${LOOP_TASK_KEY:+-$LOOP_TASK_KEY}"
      iter_archive="$iter_log_dir/$(date '+%Y-%m-%dT%H:%M:%S')${iter_suffix}.log"
      : > "$iter_archive"
    fi

    local display="${LOOP_TASK_DISPLAY:-$LOOP_TASK_KEY}"
    ralph_titlebar_update "${(U)agent_name} #$instance_num | $model_short | Iteration $iteration | $display | $(date '+%H:%M:%S')"
    echo "------- ${(U)agent_name} #$instance_num ITERATION $iteration ($display) --------"

    # Write iteration marker to session log
    echo '{"type":"_ralph_marker","iteration":'$iteration',"timestamp":"'$(date -Iseconds)'","task":"'$LOOP_TASK_KEY'"}' >> "$session_log"

    local initial_message
    initial_message=$(loop_build_context)

    # Log the full prompt for debugging: ralph debug {agent} --prompt
    local prompt_log="$instance_slot/prompt.log"
    cat > "$prompt_log" <<PROMPT_EOF
======== SYSTEM PROMPT ========
$(cat "$prompt_file")

$(cat "$provider_instructions" 2>/dev/null)
======== INITIAL MESSAGE ========
$initial_message
PROMPT_EOF

    local max_iteration_seconds="${RALPH_MAX_ITERATION_SECONDS:-1800}"

    # Write Claude output to a file (not a pipe). Child processes spawned by
    # Claude's Bash tool inherit pipe fds via fork(); if they outlive Claude
    # (e.g. dev servers), the pipe never gets EOF and `wait` blocks forever.
    local raw_output=$(mktemp)

    # Launch LLM and streaming pipeline under MONITOR so each gets its own
    # process group (enabling kill -9 -$pid to reap entire pipelines).
    # MONITOR stays on through wait so zsh can reap its own jobs.
    setopt MONITOR
    {
      ralph_exec_llm "$agent_key" "$instance_num" "$work_dir" "$prompt_file" "$provider_instructions" "$initial_message" \
        </dev/null >"$raw_output" &
    } 2>/dev/null
    child_pid=$!

    # Stream output for real-time display and session log
    local stream_pid=""
    local stream_pgid=""
    local -a tee_targets
    tee_targets=( "$session_log" )
    [[ -n "$iter_archive" ]] && tee_targets+=( "$iter_archive" )
    {
      tail -f -n +1 "$raw_output" | grep --line-buffered '^{' \
        | tee -a "${tee_targets[@]}" | jq --unbuffered -rj "$stream_text" &
    } 2>/dev/null
    stream_pid=$!
    # In zsh MONITOR mode, $! is the last pipeline member (jq) but the PGID
    # is the first member (tail). Resolve the real PGID for reliable cleanup.
    stream_pgid=$(ps -o pgid= -p $stream_pid 2>/dev/null | tr -d ' ')

    # Watchdog: force-kill if Claude hangs after max_turns
    local watchdog_pid=""
    ( sleep "$max_iteration_seconds" && ralph_log "Iteration timeout (${max_iteration_seconds}s). Force-killing..." && kill -9 -$child_pid 2>/dev/null ) &
    watchdog_pid=$!

    # Playwright budget watchdog: kill iteration if browser tool calls exceed cap
    local pw_budget="${RALPH_PLAYWRIGHT_BUDGET:-20}"
    local pw_watchdog_pid=""
    (
      local pw_count=0
      tail -f -n +1 "$raw_output" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *'"tool_name":"mcp__plugin_playwright'* ]]; then
          pw_count=$((pw_count + 1))
          if (( pw_count >= pw_budget )); then
            ralph_log "Playwright budget exhausted ($pw_count/$pw_budget). Killing iteration."
            kill -INT -$child_pid 2>/dev/null
            break
          fi
        fi
      done
    ) &
    pw_watchdog_pid=$!

    wait $child_pid 2>/dev/null || true
    kill $watchdog_pid 2>/dev/null || true; wait $watchdog_pid 2>/dev/null || true
    kill $pw_watchdog_pid 2>/dev/null || true; wait $pw_watchdog_pid 2>/dev/null || true
    # Kill the entire streaming pipeline by its real PGID (not $stream_pid which
    # is jq — the last member — and NOT the process group leader).
    if [[ -n "$stream_pgid" ]]; then
      kill -9 -$stream_pgid 2>/dev/null || true
    fi
    kill -9 -$stream_pid 2>/dev/null || true
    unsetopt MONITOR
    watchdog_pid=""
    [[ $shutdown -eq 1 ]] && _loop_die
    kill -9 -$child_pid 2>/dev/null || true
    child_pid=""

    # Kill orphaned processes (dev servers, MCP servers) left in the worktree
    ralph_cleanup_worktree_processes "$work_dir"

    # Build tmpfile from complete output (stream may have lagged)
    grep '^{' "$raw_output" > "$tmpfile" 2>/dev/null || true
    rm -f "$raw_output"

    # Post-iteration callback (e.g. worktree reset)
    if typeset -f loop_post_iteration > /dev/null 2>&1; then
      loop_post_iteration
    fi

    local result
    result=$(jq -r "$final_result" "$tmpfile" 2>/dev/null || true)
    last_task_key=$(ralph_extract_task_key "$tmpfile")

    # Overwrite the live-streamed archive with the canonical filtered output
    # (live tee may lag behind raw_output). On kill -9 mid-iteration we never
    # reach here, but the partial live archive already exists for postmortem.
    [[ -n "$iter_archive" && -s "$tmpfile" ]] && cp "$tmpfile" "$iter_archive"

    # Detect empty iterations (Claude crashed or produced no output)
    if [[ ! -s "$tmpfile" ]]; then
      consecutive_empty=$((consecutive_empty + 1))
      ralph_error "Empty output from Claude (consecutive: $consecutive_empty/$max_consecutive_empty)"
      if (( consecutive_empty >= max_consecutive_empty )); then
        ralph_error "Too many consecutive empty iterations. Aborting."
        rm -f "$tmpfile"
        exit 1
      fi
    else
      consecutive_empty=0
    fi

    # Launch reflect in background before cleaning up tmpfile
    local reflect_pid=""
    if [[ -s "$tmpfile" ]]; then
      local reflect_input
      reflect_input=$(mktemp)
      cp "$tmpfile" "$reflect_input"
      ( ralph_reflect "$agent_key" "$instance_num" "$reflect_input"; rm -f "$reflect_input" ) &
      reflect_pid=$!
    fi

    # Launch per-ticket scratchpad extraction in parallel (independent of reflect)
    local notes_pid=""
    if [[ -s "$tmpfile" && -n "$LOOP_TASK_KEY" ]]; then
      local notes_input
      notes_input=$(mktemp)
      cp "$tmpfile" "$notes_input"
      ( ralph_extract_ticket_notes "$agent_key" "$instance_num" "$notes_input" "$LOOP_TASK_KEY"; rm -f "$notes_input" ) &
      notes_pid=$!
    fi

    rm -f "$tmpfile"
    tmpfile=""

    if [[ "$result" == *"<promise>ABORT</promise>"* ]]; then
      echo "Ralph ($agent_name) aborted at iteration $iteration."
      exit 1
    fi

    # Reset same-task counter on successful completion
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      consecutive_same_task=0
    fi

    if [[ "$max_iterations" -gt 0 && "$iteration" -ge "$max_iterations" ]]; then
      ralph_log "Iteration complete. Exiting ($iteration/$max_iterations iterations)."
      exit 0
    fi

    # Wait for reflect to finish so learnings are ready for next iteration
    if [[ -n "$reflect_pid" ]]; then
      wait $reflect_pid 2>/dev/null || true
      reflect_pid=""
    fi

    ralph_log "Iteration complete. Cooldown ${poll_interval}s..."
    ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | $model_short | Iteration $iteration | Cooldown" || _loop_die
  done
}
