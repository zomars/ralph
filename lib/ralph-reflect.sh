#!/bin/zsh
# ralph-reflect.sh — Post-iteration self-improvement via learnings extraction

# ralph_reflect <agent_key> <instance_num> <session_tmpfile>
# Invokes a cheap LLM one-shot to extract learnings from the session log.
# Writes to ~/.ralph/projects/<name>/learnings/<agent>.md
ralph_reflect() {
  local agent_key="$1" instance_num="$2" session_tmpfile="$3"

  # Kill switch
  [[ "${RALPH_REFLECT:-1}" == "0" ]] && return 0

  # Need a non-empty session file
  [[ ! -s "$session_tmpfile" ]] && return 0

  local project_name="${RALPH_PROJECT:-$(basename "$PWD")}"
  local learnings_dir="$HOME/.ralph/projects/$project_name/learnings"
  local learnings_file="$learnings_dir/${agent_key}.md"
  local reflect_prompt="$RALPH_HOME/prompts/reflect.md"

  [[ ! -f "$reflect_prompt" ]] && return 0

  mkdir -p "$learnings_dir"

  # Truncate session log to last 50K chars
  local session_tail
  session_tail=$(tail -c 50000 "$session_tmpfile")

  # Build message with current learnings + session
  local current_learnings=""
  if [[ -f "$learnings_file" && -s "$learnings_file" ]]; then
    current_learnings="$(cat "$learnings_file")"
  fi

  # Write message to temp file (session logs can be huge, exceed arg limits)
  local message_file
  message_file=$(mktemp)
  cat > "$message_file" <<MSG_EOF
## Current learnings
${current_learnings:-<none>}

## Session log (last 50K chars)
$session_tail
MSG_EOF

  local reflect_model="${RALPH_REFLECT_MODEL:-claude-haiku-4-5-20251001}"

  # One-shot LLM call (use @file to avoid arg length limits)
  local output
  output=$(claude \
    --print \
    --model "$reflect_model" \
    --max-turns 1 \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat "$reflect_prompt")" \
    "@$message_file" </dev/null 2>/dev/null) || { rm -f "$message_file"; return 0; }
  rm -f "$message_file"

  # Parse <learnings>...</learnings> block
  local parsed
  parsed=$(echo "$output" | sed -n '/<learnings>/,/<\/learnings>/p' | sed '1d;$d')

  # Only write if we got something (or explicit empty = clean session)
  if [[ -n "$parsed" || "$output" == *"<learnings>"*"</learnings>"* ]]; then
    # Atomic write
    local tmp_learnings
    tmp_learnings=$(mktemp)
    echo "$parsed" > "$tmp_learnings"
    mv -f "$tmp_learnings" "$learnings_file"
    ralph_log "Reflect: updated $learnings_file ($(echo "$parsed" | grep -c '^- ') rules)"
  fi
}

# ralph_get_learnings_file <agent_key>
# Returns the path to the learnings file for injection into system prompts.
ralph_get_learnings_file() {
  local agent_key="$1"
  local project_name="${RALPH_PROJECT:-$(basename "$PWD")}"
  echo "$HOME/.ralph/projects/$project_name/learnings/${agent_key}.md"
}
