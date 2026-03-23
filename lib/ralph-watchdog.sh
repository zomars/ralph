#!/bin/zsh
# ralph-watchdog.sh — Log analysis: collect, invoke Claude, save report, apply patches

# ralph_watchdog_collect_logs [--since <duration>] [--agent <name>]
# Collects matching log files into a temp file with markers between sessions.
# Sets RALPH_WATCHDOG_COLLECTED to the path of the collected file.
ralph_watchdog_collect_logs() {
  local since="" agent_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="$2"; shift 2 ;;
      --agent) agent_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$RALPH_LOG_DIR" ]]; then
    echo "Error: RALPH_LOG_DIR is not set. Add it to your .ralphrc." >&2
    return 1
  fi

  if [[ ! -d "$RALPH_LOG_DIR" ]]; then
    echo "Error: RALPH_LOG_DIR ($RALPH_LOG_DIR) does not exist." >&2
    return 1
  fi

  local collected
  collected=$(mktemp /tmp/ralph-watchdog-collected.XXXXXX)

  # Build filename pattern
  local name_pattern="*.log"
  [[ -n "$agent_filter" ]] && name_pattern="*${agent_filter}*.log"

  local find_args=("$RALPH_LOG_DIR" -name "$name_pattern" -type f)

  # Time filter: --since takes priority, then last-run marker, then all logs
  local ref_time=""
  if [[ -n "$since" ]]; then
    local amount="${since%%[a-z]*}"
    local unit="${since##*[0-9]}"
    local seconds=0
    case "$unit" in
      m) seconds=$((amount * 60)) ;;
      h) seconds=$((amount * 3600)) ;;
      d) seconds=$((amount * 86400)) ;;
      *) echo "Error: Unknown duration unit '$unit'. Use m/h/d." >&2; return 1 ;;
    esac
    ref_time=$(mktemp /tmp/ralph-watchdog-ref.XXXXXX)
    touch -t "$(date -v-${seconds}S +%Y%m%d%H%M.%S)" "$ref_time"
    find_args+=(-newer "$ref_time")
  elif [[ -f "$RALPH_LOG_DIR/.watchdog-last-run" ]]; then
    find_args+=(-newer "$RALPH_LOG_DIR/.watchdog-last-run")
  fi

  local log_count=0
  while IFS= read -r log_file; do
    echo "--- SESSION: $(basename "$log_file") ---" >> "$collected"
    cat "$log_file" >> "$collected"
    echo "" >> "$collected"
    log_count=$((log_count + 1))
  done < <(find "${find_args[@]}" | sort)

  # Clean up temp reference file after find has used it
  [[ -n "$ref_time" ]] && rm -f "$ref_time"

  if [[ $log_count -eq 0 ]]; then
    if [[ -z "$since" && -f "$RALPH_LOG_DIR/.watchdog-last-run" ]]; then
      local last_run
      last_run=$(stat -f %Sm -t "%Y-%m-%d %H:%M" "$RALPH_LOG_DIR/.watchdog-last-run" 2>/dev/null || echo "unknown")
      echo "No new logs since last run ($last_run). Try: ralph watchdog --since 7d" >&2
    else
      echo "No log files found matching filters." >&2
    fi
    rm -f "$collected"
    return 1
  fi

  echo "Collected $log_count log file(s) for analysis." >&2
  RALPH_WATCHDOG_COLLECTED="$collected"
  return 0
}

# ralph_watchdog_run
# Invokes Claude with the watchdog prompt and collected logs.
# Sets RALPH_WATCHDOG_OUTPUT to the raw output.
ralph_watchdog_run() {
  local collected="$RALPH_WATCHDOG_COLLECTED"
  local prompt_file="$RALPH_HOME/prompts/watchdog.md"

  if [[ ! -f "$collected" ]]; then
    echo "Error: No collected logs to analyze." >&2
    return 1
  fi

  # Truncate if too large (keep last 200K chars to stay within context)
  local max_chars=200000
  local file_size
  file_size=$(wc -c < "$collected")
  if [[ $file_size -gt $max_chars ]]; then
    echo "Warning: Logs exceed ${max_chars} chars, truncating to most recent sessions." >&2
    local truncated
    truncated=$(mktemp /tmp/ralph-watchdog-trunc.XXXXXX)
    tail -c "$max_chars" "$collected" > "$truncated"
    mv "$truncated" "$collected"
  fi

  local model
  model=$(ralph_resolve_model "watchdog")
  local cli
  cli=$(ralph_get_agent_cli)

  echo "Running watchdog analysis (model: $model)..." >&2

  local tmpfile
  tmpfile=$(mktemp /tmp/ralph-watchdog-output.XXXXXX)

  local log_content
  log_content=$(<"$collected")

  "$cli" --verbose --print --max-turns 50 --output-format stream-json \
    --model "$model" \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat "$prompt_file")" \
    "Analyze these Ralph agent session logs and identify patterns:

$log_content" \
    2>/dev/null \
    | grep --line-buffered '^{' \
    | tee "$tmpfile" \
    | jq -rj 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null

  # Extract final text from stream-json
  RALPH_WATCHDOG_OUTPUT=$(grep '^{' "$tmpfile" \
    | jq -rj 'select(.type == "result") | .result // empty' 2>/dev/null)

  # Fallback: concatenate assistant text blocks
  if [[ -z "$RALPH_WATCHDOG_OUTPUT" ]]; then
    RALPH_WATCHDOG_OUTPUT=$(grep '^{' "$tmpfile" \
      | jq -rj 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null)
  fi

  rm -f "$tmpfile" "$collected"
  return 0
}

# ralph_watchdog_save_report
# Extracts <report> from output and saves to RALPH_LOG_DIR.
ralph_watchdog_save_report() {
  local output="$RALPH_WATCHDOG_OUTPUT"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local report_file="$RALPH_LOG_DIR/watchdog-report-${timestamp}.md"

  # Extract content between <report> tags
  local report
  report=$(echo "$output" | sed -n '/<report>/,/<\/report>/p' | sed '1d;$d')

  if [[ -z "$report" ]]; then
    echo "Warning: No <report> section found in output." >&2
    # Save full output as fallback
    echo "$output" > "$report_file"
  else
    echo "$report" > "$report_file"
  fi

  echo "Report saved: $report_file" >&2

  # Update last-run timestamp
  touch "$RALPH_LOG_DIR/.watchdog-last-run"
}

# ralph_watchdog_print_patch
# Extracts <claude-md-patch> and prints to stdout.
ralph_watchdog_print_patch() {
  local output="$RALPH_WATCHDOG_OUTPUT"

  local patch
  patch=$(echo "$output" | sed -n '/<claude-md-patch>/,/<\/claude-md-patch>/p' | sed '1d;$d')

  if [[ -n "$patch" ]]; then
    echo ""
    echo "=== Suggested CLAUDE.md patch ==="
    echo "$patch"
    echo "================================="
  else
    echo "No CLAUDE.md patches suggested." >&2
  fi
}

# ralph_watchdog_apply_patch <target_claude_md>
# Appends patch content to the target CLAUDE.md if not already present.
ralph_watchdog_apply_patch() {
  local target="${1:-.}"
  local claude_md="$target/CLAUDE.md"

  if [[ ! -f "$claude_md" ]]; then
    echo "Error: $claude_md not found." >&2
    return 1
  fi

  local output="$RALPH_WATCHDOG_OUTPUT"
  local patch
  patch=$(echo "$output" | sed -n '/<claude-md-patch>/,/<\/claude-md-patch>/p' | sed '1d;$d')

  if [[ -z "$patch" ]]; then
    echo "No patches to apply." >&2
    return 0
  fi

  # Check for duplicate — if the first rule line already exists, skip
  local first_rule
  first_rule=$(echo "$patch" | grep -m1 '^- ' || true)
  if [[ -n "$first_rule" ]] && grep -qF "$first_rule" "$claude_md" 2>/dev/null; then
    echo "Patch already present in $claude_md — skipping." >&2
    return 0
  fi

  echo "" >> "$claude_md"
  echo "$patch" >> "$claude_md"
  echo "Appended watchdog learnings to $claude_md" >&2
}
