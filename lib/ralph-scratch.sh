#!/bin/zsh
# ralph-scratch.sh — Per-ticket scratchpad: state that survives across iterations
# on the same ticket. Mirrors ralph-reflect.sh but scoped per-ticket instead of
# per project+agent. The working agent does not see this file's authoring — a
# post-iteration haiku one-shot extracts notes from the iteration log.

# ralph_get_scratch_file <agent_key> <ticket_key>
# Returns the path to the scratch file for a given agent+ticket pair.
ralph_get_scratch_file() {
  local agent_key="$1" ticket_key="$2"
  [[ -z "$ticket_key" ]] && return 1
  local project_name="${RALPH_PROJECT:-$(basename "$PWD")}"
  echo "$HOME/.ralph/projects/$project_name/scratch/$agent_key/${ticket_key}.md"
}

# ralph_extract_ticket_notes <agent_key> <instance_num> <session_tmpfile> <task_key>
# Invokes a cheap LLM one-shot to extract per-ticket working notes from the
# session log. Writes to scratch/<agent>/<TICKET>.md, or deletes the file if
# the model returns an empty <ticket_notes></ticket_notes> block (signal that
# the ticket is done with).
ralph_extract_ticket_notes() {
  local agent_key="$1" instance_num="$2" session_tmpfile="$3" task_key="$4"

  # Kill switch
  [[ "${RALPH_TICKET_NOTES:-1}" == "0" ]] && return 0

  [[ -z "$task_key" ]] && return 0
  [[ ! -s "$session_tmpfile" ]] && return 0

  local notes_prompt="$RALPH_HOME/prompts/ticket-notes.md"
  [[ ! -f "$notes_prompt" ]] && return 0

  local scratch_file
  scratch_file=$(ralph_get_scratch_file "$agent_key" "$task_key") || return 0
  mkdir -p "$(dirname "$scratch_file")"

  local current_notes=""
  if [[ -f "$scratch_file" && -s "$scratch_file" ]]; then
    current_notes="$(cat "$scratch_file")"
  fi

  # Same cap as reflect — feed the whole iteration log when it fits.
  local max_bytes="${RALPH_REFLECT_MAX_BYTES:-2097152}"
  local session_size
  session_size=$(wc -c < "$session_tmpfile" 2>/dev/null | tr -d ' ')
  local session_full
  if [[ -n "$session_size" ]] && (( session_size > max_bytes )); then
    session_full=$(tail -c "$max_bytes" "$session_tmpfile")
  else
    session_full=$(cat "$session_tmpfile")
  fi

  local message_file
  message_file=$(mktemp)
  cat > "$message_file" <<MSG_EOF
## Ticket
$task_key

## Current notes
${current_notes:-<none>}

## Iteration log
$session_full
MSG_EOF

  local notes_model="${RALPH_TICKET_NOTES_MODEL:-${RALPH_REFLECT_MODEL:-claude-haiku-4-5-20251001}}"

  local output
  output=$(claude \
    --print \
    --model "$notes_model" \
    --max-turns 1 \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat "$notes_prompt")" \
    "@$message_file" </dev/null 2>/dev/null) || { rm -f "$message_file"; return 0; }
  rm -f "$message_file"

  # Parse <ticket_notes>...</ticket_notes> block
  local parsed
  parsed=$(echo "$output" | sed -n '/<ticket_notes>/,/<\/ticket_notes>/p' | sed '1d;$d')

  # Only act if we got a complete block
  if [[ "$output" == *"<ticket_notes>"*"</ticket_notes>"* ]]; then
    if [[ -z "${parsed//[[:space:]]/}" ]]; then
      rm -f "$scratch_file"
      ralph_log "Scratchpad: cleared $scratch_file"
    else
      local tmp_scratch
      tmp_scratch=$(mktemp)
      echo "$parsed" > "$tmp_scratch"
      mv -f "$tmp_scratch" "$scratch_file"
      ralph_log "Scratchpad: updated $scratch_file ($(echo "$parsed" | grep -c '^- ') bullets)"
    fi
  fi
}
