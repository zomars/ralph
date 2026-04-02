#!/bin/zsh
# ralph-llm.sh — LLM invocation: model resolution, CLI dispatch, jq filters

# ralph_resolve_model <agent_key>
# Returns the model ID for the given agent. Resolution order:
#   1. RALPH_<AGENT>_MODEL env var (per-agent override)
#   2. RALPH_MODEL env var (global override)
#   3. Built-in default per agent
# Short aliases: haiku, sonnet, opus → full model IDs
ralph_resolve_model() {
  local agent_key="$1"
  local agent_upper="${agent_key:u}"
  local var_name="RALPH_${agent_upper}_MODEL"
  local model="${(P)var_name}"

  if [[ -z "$model" ]]; then
    model="${RALPH_MODEL:-}"
  fi

  if [[ -z "$model" ]]; then
    case "$agent_key" in
      planner)     model="opus" ;;
      documenter)  model="haiku" ;;
      merger)      model="haiku" ;;
      *)           model="sonnet" ;;
    esac
  fi

  # Map short aliases to full model IDs
  case "$model" in
    haiku)  echo "claude-haiku-4-5-20251001" ;;
    sonnet) echo "claude-sonnet-4-6" ;;
    opus)   echo "claude-opus-4-6" ;;
    *)      echo "$model" ;;
  esac
}

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

  # Inject learnings from past iterations if available
  local learnings_file
  learnings_file=$(ralph_get_learnings_file "$agent_key")
  if [[ -f "$learnings_file" && -s "$learnings_file" ]]; then
    full_system_prompt="$full_system_prompt

# LEARNINGS FROM PAST ITERATIONS
$(cat "$learnings_file")"
  fi

  case "$agent_cli" in
    claude)
      local model
      model=$(ralph_resolve_model "$agent_key")
      ralph_log "Model: $model"
      (cd "$work_dir" && claude \
        --verbose \
        --print \
        --model "$model" \
        --max-turns 100 \
        --output-format stream-json \
        --dangerously-skip-permissions \
        --disallowedTools ToolSearch \
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
