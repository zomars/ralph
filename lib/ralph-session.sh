#!/bin/zsh
# ralph-session.sh — Session log extraction and persistence

# ralph_extract_task_key <file>
# Scans stream-json output for a task key (e.g. PROD-42). Returns first match or empty.
ralph_extract_task_key() {
  local file="$1"
  [[ ! -f "$file" ]] && return
  jq -r '.text // empty' "$file" 2>/dev/null | grep -oE '[A-Z][A-Z0-9]+-[0-9]+|#[0-9]+' | head -1
}

# ralph_save_session_log <session_log> <agent_key> <instance_num> [task_key]
# Copies session log to persistent log dir on exit. No-op if RALPH_LOG_DIR is unset.
ralph_save_session_log() {
  [[ -z "$RALPH_LOG_DIR" ]] && return
  local session_log="$1" agent_key="$2" instance_num="$3" task_key="$4"
  [[ ! -f "$session_log" ]] && return
  [[ ! -s "$session_log" ]] && return  # skip empty logs (idle polls)

  local log_dir="${RALPH_LOG_DIR%/}/${agent_key}-${instance_num}"
  mkdir -p "$log_dir"

  local timestamp
  timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
  local suffix="${task_key:+-$task_key}"
  local log_path="$log_dir/${timestamp}${suffix}.log"
  cp "$session_log" "$log_path"
  ralph_log "Session log: $log_path"
}
