#!/bin/zsh
# ralph-core.sh — Shared functions for Ralph agent ecosystem

# ─── Init ─────────────────────────────────────────────────────────────────────

ralph_init() {
  # Resolve RALPH_HOME via realpath (works through npm symlinks)
  if [[ -z "$RALPH_HOME" ]]; then
    RALPH_HOME="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
  fi
  export RALPH_HOME

  # Load .ralphrc from CWD if present
  if [[ -f ".ralphrc" ]]; then
    source ".ralphrc"
  fi

  # Default provider
  export RALPH_PROVIDER="${RALPH_PROVIDER:-jira}"

  # Default model provider (LLM CLI)
  export RALPH_MODEL_PROVIDER="${RALPH_MODEL_PROVIDER:-claude}"

  case "$RALPH_MODEL_PROVIDER" in
    claude|gemini|codex) ;;
    *)
      ralph_error "Unknown RALPH_MODEL_PROVIDER: $RALPH_MODEL_PROVIDER (expected: claude, gemini, codex)"
      exit 1
      ;;
  esac
}

# ─── Agent CLI ────────────────────────────────────────────────────────────────

# ralph_get_agent_cli
# Returns the command to invoke the configured agent CLI.
ralph_get_agent_cli() {
  case "$RALPH_MODEL_PROVIDER" in
    gemini) echo "gemini" ;;
    codex)  echo "codex" ;;
    *)      echo "claude" ;;
  esac
}

# ralph_get_jq_filters
# Returns the jq filters for streaming and result extraction based on the provider.
# Sets RALPH_STREAM_FILTER and RALPH_RESULT_FILTER.
ralph_get_jq_filters() {
  case "$RALPH_MODEL_PROVIDER" in
    gemini)
      # Gemini stream-json: {"type":"message","role":"assistant","content":"..."}
      export RALPH_STREAM_FILTER='select(.type == "message" and .role == "assistant").content // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
      # Gemini result event has no text — scan all assistant messages for promise detection
      export RALPH_RESULT_FILTER='select(.type == "message" and .role == "assistant").content // empty'
      ;;
    codex)
      # Codex --json: {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
      export RALPH_STREAM_FILTER='select(.type == "item.completed").item | select(.type == "agent_message").text // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
      # Scan all agent_message items for promise detection
      export RALPH_RESULT_FILTER='select(.type == "item.completed").item | select(.type == "agent_message").text // empty'
      ;;
    *)
      # Default (Claude)
      export RALPH_STREAM_FILTER='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
      export RALPH_RESULT_FILTER='select(.type == "result").result // empty'
      ;;
  esac
}

# ralph_exec_llm <agent_key> <instance_num> <work_dir> <prompt_file> <provider_instructions> <initial_message>
# Executes the configured LLM CLI with provider-specific flags.
# Outputs stream-json to stdout.
ralph_exec_llm() {
  local agent_key="$1" instance_num="$2" work_dir="$3" prompt_file="$4" provider_instructions="$5" initial_message="$6"
  local agent_cli
  agent_cli=$(ralph_get_agent_cli)

  local full_system_prompt
  if [[ -n "$provider_instructions" && -f "$provider_instructions" ]]; then
    full_system_prompt="$(cat "$prompt_file")

$(cat "$provider_instructions")"
  else
    full_system_prompt="$(cat "$prompt_file")"
  fi

  case "$agent_cli" in
    claude)
      (cd "$work_dir" && claude \
        --verbose \
        --print \
        --max-turns 100 \
        --output-format stream-json \
        --dangerously-skip-permissions \
        --append-system-prompt "$full_system_prompt" \
        "$initial_message")
      ;;
    gemini)
      # GEMINI_SYSTEM_MD replaces built-in system prompt with file contents
      # --approval-mode yolo auto-approves all tool calls (--yolo is deprecated)
      # Positional arg triggers headless mode (--prompt/-p is deprecated)
      local sys_tmp
      sys_tmp=$(mktemp)
      echo "$full_system_prompt" > "$sys_tmp"

      (cd "$work_dir" && GEMINI_SYSTEM_MD="$sys_tmp" gemini \
        --debug \
        --approval-mode yolo \
        --max-turns 100 \
        --output-format stream-json \
        "$initial_message")
      local exit_code=$?
      rm -f "$sys_tmp"
      return $exit_code
      ;;
    codex)
      # Codex reads AGENTS.override.md from project root for instructions
      # codex exec runs in headless mode; --json produces JSONL to stdout
      echo "$full_system_prompt" > "$work_dir/AGENTS.override.md"

      (cd "$work_dir" && codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        --json \
        "$initial_message")
      local exit_code=$?
      rm -f "$work_dir/AGENTS.override.md"
      return $exit_code
      ;;
  esac
}

# ─── Worktrees ────────────────────────────────────────────────────────────────

# ralph_setup_worktree <agent_key> <instance_num>
# Creates (or reuses) a persistent git worktree for this agent instance.
# Sets globals: RALPH_WORKTREE_DIR (path) and RALPH_WORKTREE_CONTEXT (setup output).
# Must be called directly (not in a subshell) so globals propagate to the caller.
# Runs RALPH_WORKTREE_SETUP if set, otherwise auto-detects scripts/worktree-setup.sh.
ralph_setup_worktree() {
  local agent_key="$1" instance_num="$2"
  # Return values via globals (not stdout) to avoid $() subshell losing exports
  RALPH_WORKTREE_DIR="/tmp/ralph-worktrees/${agent_key}-${instance_num}"
  RALPH_WORKTREE_CONTEXT=""

  if [[ ! -d "$RALPH_WORKTREE_DIR" ]]; then
    local branch_name="ralph-workspace/${agent_key}-${instance_num}"
    # Remove stale worktree entry if git still tracks it
    git worktree prune 2>/dev/null || true
    # Delete stale branch if it exists but worktree is gone
    git branch -D "$branch_name" >/dev/null 2>&1 || true
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      # Branch couldn't be deleted (e.g. checked out in main repo) — reuse it
      git worktree add "$RALPH_WORKTREE_DIR" "$branch_name" --quiet
    else
      git worktree add "$RALPH_WORKTREE_DIR" -b "$branch_name" HEAD --quiet
    fi
  fi

  # Build .mcp.json: start from project's copy (or empty), layer provider MCP on top,
  # then commit so reset --hard between iterations preserves it.
  git show HEAD:.mcp.json > "$RALPH_WORKTREE_DIR/.mcp.json" 2>/dev/null \
    || echo '{}' > "$RALPH_WORKTREE_DIR/.mcp.json"

  if [[ -n "${PROVIDER_MCP_NAME:-}" ]] && command -v "${PROVIDER_MCP_CMD:-}" &>/dev/null; then
    jq --arg n "$PROVIDER_MCP_NAME" --arg c "$PROVIDER_MCP_CMD" \
      '.mcpServers[$n] = {"command": $c}' "$RALPH_WORKTREE_DIR/.mcp.json" \
      > "$RALPH_WORKTREE_DIR/.mcp.json.tmp" && mv "$RALPH_WORKTREE_DIR/.mcp.json.tmp" "$RALPH_WORKTREE_DIR/.mcp.json"
  fi

  git -C "$RALPH_WORKTREE_DIR" add .mcp.json \
    && git -C "$RALPH_WORKTREE_DIR" commit --no-verify -m "ralph: configure MCP servers" 2>/dev/null || true

  # Run project-specific worktree setup.
  # Priority: explicit RALPH_WORKTREE_SETUP > auto-detect scripts/worktree-setup.sh
  # Stdout is captured into RALPH_WORKTREE_CONTEXT for the agent; stderr passes through.
  local setup_cmd="${RALPH_WORKTREE_SETUP:-}"
  if [[ -z "$setup_cmd" && -f "$RALPH_WORKTREE_DIR/scripts/worktree-setup.sh" ]]; then
    setup_cmd="bash scripts/worktree-setup.sh"
  fi
  if [[ -n "$setup_cmd" ]]; then
    ralph_log "Running worktree setup: $setup_cmd"
    local setup_output=""
    setup_output=$(cd "$RALPH_WORKTREE_DIR" && eval "$setup_cmd") || {
      ralph_error "Worktree setup failed (exit $?). Continuing anyway."
    }
    if [[ -n "$setup_output" ]]; then
      RALPH_WORKTREE_CONTEXT="$setup_output"
      ralph_log "Worktree context captured (${#setup_output} bytes)"
    fi
  fi
}

# ralph_cleanup_worktree <work_dir>
# Removes a worktree directory and its tracking branch.
ralph_cleanup_worktree() {
  local work_dir="$1"
  [[ -d "$work_dir" ]] && git worktree remove "$work_dir" --force 2>/dev/null || true
  git worktree prune 2>/dev/null || true
}

# ralph_cleanup_worktree_processes <work_dir>
# Kills any processes still referencing the worktree directory.
# Catches orphaned dev servers, MCP servers, etc. that survive after Claude exits.
ralph_cleanup_worktree_processes() {
  local work_dir="$1"
  [[ -z "$work_dir" ]] && return
  local my_pid=$$
  local pids=()
  local pid
  for pid in $(pgrep -f "$work_dir" 2>/dev/null); do
    [[ "$pid" == "$my_pid" ]] && continue
    pids+=("$pid")
  done
  (( ${#pids} == 0 )) && return
  ralph_log "Cleaning up ${#pids} lingering process(es) in worktree..."
  kill -TERM "${pids[@]}" 2>/dev/null
  sleep 2
  kill -9 "${pids[@]}" 2>/dev/null || true
}

# ─── Logging ──────────────────────────────────────────────────────────────────

ralph_log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

ralph_error() {
  echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2
}

# ─── Environment ──────────────────────────────────────────────────────────────

ralph_validate_env() {
  local var
  for var in "$@"; do
    if [[ -z "${(P)var}" ]]; then
      ralph_error "$var is not set"
      exit 1
    fi
  done
}

# ─── Paths ────────────────────────────────────────────────────────────────────

ralph_get_prompt() {
  local agent="$1"
  echo "$RALPH_HOME/prompts/$agent.md"
}

ralph_get_provider_instructions() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/instructions.md"
}

ralph_get_routing_json() {
  echo "$RALPH_HOME/providers/$RALPH_PROVIDER/routing.json"
}

# ─── Provider ─────────────────────────────────────────────────────────────────

ralph_load_provider() {
  local provider_script="$RALPH_HOME/lib/providers/$RALPH_PROVIDER.sh"
  if [[ ! -f "$provider_script" ]]; then
    ralph_error "Provider not found: $RALPH_PROVIDER (expected $provider_script)"
    exit 1
  fi
  source "$provider_script"
}

# ─── Queries ──────────────────────────────────────────────────────────────────

ralph_get_query() {
  local agent="$1"
  # Generate query from rules via the provider's rules_to_query function.
  # The provider must be sourced before calling this (see ralph-gated-loop.sh).
  provider_rules_to_query "$agent"
}


# ─── Session Logs ────────────────────────────────────────────────────────

# ralph_extract_task_key <file>
# Scans stream-json output for a task key (e.g. PROD-42). Returns first match or empty.
ralph_extract_task_key() {
  local file="$1"
  [[ ! -f "$file" ]] && return
  jq -r '.text // empty' "$file" 2>/dev/null | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1
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

# ─── Config ───────────────────────────────────────────────────────────────────

ralph_get_poll_interval() {
  echo "${RALPH_POLL_INTERVAL:-15}"
}

# ralph_cooldown <seconds> <title_prefix>
# Counts down in the titlebar, sleeping 1s at a time.
# Respects $shutdown and $child_pid for clean signal handling.
ralph_cooldown() {
  local remaining="$1" prefix="$2"
  while (( remaining > 0 )); do
    ralph_titlebar_update "$prefix | Next poll: ${remaining}s"
    sleep 1 &
    child_pid=$!
    wait $child_pid 2>/dev/null || true
    child_pid=""
    [[ $shutdown -eq 1 ]] && return 1
    remaining=$((remaining - 1))
  done
}

# ─── Title Bar ───────────────────────────────────────────────────────────────

_ralph_titlebar_text=""
_ralph_titlebar_active=0

ralph_titlebar_init() {
  local rows
  rows=$(tput lines)
  _ralph_titlebar_active=1
  # Clear screen, move to 1;1, set scroll region 2–bottom, position at line 2
  printf '\033[2J\033[1;1H\033[2K\033[2;%sr\033[2;1H' "$rows" >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_resize() {
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  # Update scroll region to new size
  printf '\033[s\033[2;%sr' "$rows" >/dev/tty
  # Redraw the title if we have one
  if [[ -n "$_ralph_titlebar_text" ]]; then
    local text="${_ralph_titlebar_text[1,$cols]}"
    printf '\033[1;1H\033[2K\033[7m%-*s\033[0m' "$cols" "$text" >/dev/tty
  fi
  printf '\033[u' >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_update() {
  local text="$1" cols
  _ralph_titlebar_text="$text"
  cols=$(tput cols)
  text="${text[1,$cols]}"
  # Save cursor, move to 1;1, write full-width inverse bar, restore cursor
  printf '\033[s\033[1;1H\033[2K\033[7m%-*s\033[0m\033[u' "$cols" "$text" >/dev/tty
}

ralph_titlebar_cleanup() {
  [[ $_ralph_titlebar_active -eq 0 ]] && return
  _ralph_titlebar_text=""
  _ralph_titlebar_active=0
  # Reset scroll region to full screen, clear the title bar line
  printf '\033[r\033[1;1H\033[2K' >/dev/tty
}
