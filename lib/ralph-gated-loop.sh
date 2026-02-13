#!/bin/zsh
# ralph-gated-loop.sh — Parameterized backlog-gated AFK loop
#
# Usage: source this file, then call ralph_gated_loop <agent_key> <agent_name>

ralph_gated_loop() {
  local agent_key="$1"
  local agent_name="$2"

  # ─── Init ─────────────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-core.sh"
  ralph_init
  ralph_load_provider

  # Validate provider-specific env vars
  ralph_validate_env $PROVIDER_ENV_VARS

  # Resolve paths
  local jql prompt_file provider_instructions poll_interval
  jql="$(ralph_get_jql "$agent_key")"
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
  local stream_text='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
  local final_result='select(.type == "result").result // empty'

  # ─── State ──────────────────────────────────────────────────────────────
  local iteration=0
  local tmpfile=""
  local child_pid=""
  local shutdown=0

  trap 'shutdown=1' INT TERM
  trap 'rm -f "$tmpfile" 2>/dev/null' EXIT

  die() {
    printf "\nShutting down.\n"
    rm -f "$tmpfile" 2>/dev/null
    tmpfile=""
    [[ -n "$child_pid" ]] && kill -9 "$child_pid" 2>/dev/null
    kill -9 0 2>/dev/null
    exit 1
  }

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    local task_count
    task_count=$(provider_check_tasks "$jql")

    if [[ "$task_count" -eq 0 ]]; then
      ralph_log "No $agent_name tasks assigned. Sleeping ${poll_interval}s..."
      sleep "$poll_interval" &
      child_pid=$!
      wait $child_pid 2>/dev/null || true
      child_pid=""
      [[ $shutdown -eq 1 ]] && die
      continue
    fi

    iteration=$((iteration + 1))
    tmpfile=$(mktemp)

    echo "------- ${(U)agent_name} ITERATION $iteration ($task_count tasks) --------"

    claude \
      --verbose \
      --print \
      --max-turns 100 \
      --output-format stream-json \
      --dangerously-skip-permissions \
      --append-system-prompt "$(cat "$provider_instructions")" \
      "@$prompt_file" \
    | grep --line-buffered '^{' \
    | tee "$tmpfile" \
    | jq --unbuffered -rj "$stream_text" &
    child_pid=$!
    wait $child_pid 2>/dev/null || true
    child_pid=""
    [[ $shutdown -eq 1 ]] && die

    local result
    result=$(jq -r "$final_result" "$tmpfile")
    rm -f "$tmpfile"
    tmpfile=""

    if [[ "$result" == *"<promise>ABORT</promise>"* ]]; then
      echo "Ralph ($agent_name) aborted at iteration $iteration."
      exit 1
    fi

    ralph_log "Iteration complete. Cooldown ${poll_interval}s..."
    sleep "$poll_interval" &
    child_pid=$!
    wait $child_pid 2>/dev/null || true
    child_pid=""
    [[ $shutdown -eq 1 ]] && die
  done
}
