#!/bin/zsh
set -e

# Jira-gated AFK loop for Ralph (Reviewer Mode)
# Checks into Jira for "In Review" tasks.

# Required env vars:
#   JIRA_EMAIL      - Your Atlassian email
#   JIRA_API_TOKEN  - Personal Access Token
#   JIRA_BASE_URL   - e.g. https://yourorg.atlassian.net

for var in JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL; do
  if [ -z "${(P)var}" ]; then
    echo "Error: $var is not set"
    exit 1
  fi
done

POLL_INTERVAL="${RALPH_POLL_INTERVAL:-300}"
ROUTING_JSON="$(dirname "$0")/routing.json"
AGENT_KEY="reviewer"
JQL=$(jq -r ".agents.${AGENT_KEY}.jql" "$ROUTING_JSON")

# jq filters
stream_text='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
final_result='select(.type == "result").result // empty'

iteration=0
tmpfile=""
child_pid=""
shutdown=0

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

check_jira() {
  local response
  response=$(curl -s --fail-with-body -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"jql\":\"$JQL\",\"maxResults\":1,\"fields\":[\"summary\"]}" \
    "$JIRA_BASE_URL/rest/api/3/search/jql" 2>&1)

  if [[ $? -ne 0 ]]; then
    echo "[$(date '+%H:%M:%S')] Jira check failed: $response" >&2
    echo "0"
    return
  fi

  echo "$response" | jq '.issues | length'
}

while true; do
  task_count=$(check_jira)

  if [[ "$task_count" -eq 0 ]]; then
    echo "[$(date '+%H:%M:%S')] No Review tasks assigned. Sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL" &
    child_pid=$!
    wait $child_pid 2>/dev/null || true
    child_pid=""
    [[ $shutdown -eq 1 ]] && die
    continue
  fi

  iteration=$((iteration + 1))
  tmpfile=$(mktemp)

  echo "------- REVIEWER ITERATION $iteration ($task_count tasks) --------"

  claude \
    --verbose \
    --print \
    --output-format stream-json \
    --dangerously-skip-permissions \
    "@ralph/prompt-reviewer.md" \
  | grep --line-buffered '^{' \
  | tee "$tmpfile" \
  | jq --unbuffered -rj "$stream_text" &
  child_pid=$!
  wait $child_pid 2>/dev/null || true
  child_pid=""
  [[ $shutdown -eq 1 ]] && die

  result=$(jq -r "$final_result" "$tmpfile")
  rm -f "$tmpfile"
  tmpfile=""

  if [[ "$result" == *"<promise>ABORT</promise>"* ]]; then
    echo "Ralph (Reviewer) aborted at iteration $iteration."
    exit 1
  fi

  echo "[$(date '+%H:%M:%S')] Iteration complete. Cooldown ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL" &
  child_pid=$!
  wait $child_pid 2>/dev/null || true
  child_pid=""
  [[ $shutdown -eq 1 ]] && die

 done
