#!/bin/zsh
# ralph-github-loop.sh — GitHub PR-gated AFK loop
#
# Usage: source this file, then call ralph_github_loop <agent_key> <agent_name>
# Unlike ralph-gated-loop.sh, this does NOT use a Jira provider.
# It gates on GitHub PRs needing attention (changes requested / unresolved comments).

ralph_check_github_prs() {
  local cr commented
  cr=$(gh pr list --author "@me" --search "review:changes_requested" \
    --json number --jq 'length' 2>/dev/null) || cr=0
  commented=$(gh pr list --author "@me" --search "review:commented -review:approved" \
    --json number --jq 'length' 2>/dev/null) || commented=0
  echo $(( cr > commented ? cr : commented ))
}

ralph_github_loop_once() {
  ralph_github_loop "$1" "$2" "true"
}

ralph_github_loop() {
  local agent_key="$1"
  local agent_name="$2"
  local run_once="${3:-false}"

  # ─── Init ─────────────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-core.sh"
  ralph_init

  # Validate gh CLI is available
  if ! command -v gh &>/dev/null; then
    ralph_error "gh CLI is not installed. Install it: https://cli.github.com/"
    exit 1
  fi
  if ! gh auth status &>/dev/null; then
    ralph_error "gh CLI is not authenticated. Run: gh auth login"
    exit 1
  fi

  # ─── Instance slot ────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-gated-loop.sh"
  local instance_num instance_slot
  instance_num=$(ralph_claim_instance "$agent_key")
  instance_slot="/tmp/ralph-${agent_key}/${instance_num}"

  # Resolve paths
  local prompt_file poll_interval
  prompt_file="$(ralph_get_prompt "$agent_key")"
  poll_interval="$(ralph_get_poll_interval)"

  if [[ ! -f "$prompt_file" ]]; then
    ralph_error "Prompt not found: $prompt_file"
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
  trap 'ralph_titlebar_cleanup; rm -f "$tmpfile" 2>/dev/null; rm -rf "$instance_slot" 2>/dev/null' EXIT

  die() {
    ralph_titlebar_cleanup
    printf "\nShutting down.\n"
    rm -f "$tmpfile" 2>/dev/null
    tmpfile=""
    rm -rf "$instance_slot" 2>/dev/null
    [[ -n "$child_pid" ]] && kill -9 "$child_pid" 2>/dev/null
    kill -9 0 2>/dev/null
    exit 1
  }

  ralph_titlebar_init

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    local pr_count
    pr_count=$(ralph_check_github_prs)

    if [[ "$pr_count" -lt "$instance_num" ]]; then
      if [[ "$run_once" == "true" ]]; then
        ralph_log "No PRs needing fixes for instance #$instance_num ($pr_count available). Exiting (--once mode)."
        exit 0
      fi
      ralph_log "Not enough PRs for instance #$instance_num ($pr_count available). Sleeping ${poll_interval}s..."
      ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | Waiting" || die
      continue
    fi

    iteration=$((iteration + 1))
    tmpfile=$(mktemp)

    ralph_titlebar_update "${(U)agent_name} #$instance_num | Iteration $iteration | PRs: $pr_count | $(date '+%H:%M:%S')"
    echo "------- ${(U)agent_name} #$instance_num ITERATION $iteration ($pr_count PRs) --------"

    claude \
      --verbose \
      --print \
      --max-turns 100 \
      --output-format stream-json \
      --dangerously-skip-permissions \
      --append-system-prompt "$(cat "$prompt_file")" \
      "You are RALPH_${(U)agent_key}, instance $instance_num. Execute your workflow now. Start with Step 1." \
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

    if [[ "$run_once" == "true" ]]; then
      ralph_log "Iteration complete. Exiting (--once mode)."
      exit 0
    fi

    ralph_log "Iteration complete. Cooldown ${poll_interval}s..."
    ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | Cooldown" || die
  done
}
