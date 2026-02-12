#!/bin/zsh
# ralph-iter-loop.sh — Parameterized N-iteration loop
#
# Usage: source this file, then call ralph_iter_loop <iterations> <prompt_file>

ralph_iter_loop() {
  local iterations="$1"
  local prompt_file="$2"

  # ─── Init ─────────────────────────────────────────────────────────────────
  source "$RALPH_HOME/lib/ralph-core.sh"
  ralph_init

  local provider_instructions
  provider_instructions="$(ralph_get_provider_instructions)"

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

  # ─── Iteration loop ────────────────────────────────────────────────────
  local i
  for ((i=1; i<=iterations; i++)); do
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f $tmpfile" EXIT

    echo "------- ITERATION $i --------"

    claude \
      --verbose \
      --print \
      --output-format stream-json \
      --dangerously-skip-permissions \
      --append-system-prompt "$(cat "$provider_instructions")" \
      "$prompt_file" \
    | grep --line-buffered '^{' \
    | tee "$tmpfile" \
    | jq --unbuffered -rj "$stream_text"

    local result
    result=$(jq -r "$final_result" "$tmpfile")
    rm -f "$tmpfile"

    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      echo "Ralph complete after $i iterations."
      exit 0
    fi

    if [[ "$result" == *"<promise>ABORT</promise>"* ]]; then
      echo "Ralph aborted after $i iterations."
      exit 1
    fi
  done
}
