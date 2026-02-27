#!/bin/zsh
# ralph-github-loop.sh — GitHub PR-gated AFK loop
#
# Usage: source this file, then call ralph_github_loop <agent_key> <agent_name>
# Unlike ralph-gated-loop.sh, this does NOT use a Jira provider.
# It gates on GitHub PRs needing attention (changes requested / unresolved comments).

ralph_fetch_github_prs() {
  # Fetch PRs with unresolved review threads (catches both human and bot feedback).
  # Returns a JSON array of {number, title, url, headRefName} for PRs needing fixes.
  # Scoped to the current repo via gh's default repo detection.
  local repo
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || repo=""
  if [[ -z "$repo" ]]; then
    echo "[]"
    return
  fi

  # Single GraphQL query fetches everything the fixer needs.
  # Selects PRs with unresolved review threads OR merge conflicts.
  # We also merge in PRs with formal "changes requested" via gh pr list
  # (those may not have unresolved threads yet).
  local graphql_prs cr_prs
  graphql_prs=$(gh api graphql -f query="
    {
      search(query: \"is:pr is:open author:@me repo:$repo\", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            mergeable
            reviewThreads(first: 100) {
              nodes { isResolved }
            }
          }
        }
      }
    }" --jq '[.data.search.nodes[] |
      { hasUnresolvedThreads: (.reviewThreads.nodes | map(select(.isResolved == false)) | length > 0),
        hasConflicts: (.mergeable == "CONFLICTING") } as $flags |
      select($flags.hasUnresolvedThreads or $flags.hasConflicts) |
      {number, title, url, headRefName, hasConflicts: $flags.hasConflicts}
    ]' 2>/dev/null) || graphql_prs="[]"

  cr_prs=$(gh pr list --author "@me" --search "review:changes_requested" \
    --json number,title,url,headRefName 2>/dev/null) || cr_prs="[]"

  # Merge and deduplicate by PR number, preferring graphql_prs entries (which carry hasConflicts)
  echo "$graphql_prs"$'\n'"$cr_prs" \
    | jq -s 'add | group_by(.number) | map(first | .hasConflicts = (.hasConflicts // false)) | sort_by(.number)'
}

ralph_check_github_prs() {
  ralph_fetch_github_prs | jq 'length'
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

  # ─── Worktree ───────────────────────────────────────────────────────────
  local project_dir="$PWD"
  local work_dir
  work_dir=$(ralph_setup_worktree "$agent_key" "$instance_num")

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

  trap 'shutdown=1' INT TERM HUP
  trap 'ralph_titlebar_cleanup; rm -f "$tmpfile" 2>/dev/null; rm -rf "$instance_slot" 2>/dev/null; ralph_cleanup_worktree "$work_dir"; [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null; kill -9 0 2>/dev/null' EXIT

  die() {
    ralph_titlebar_cleanup
    printf "\nShutting down.\n"
    rm -f "$tmpfile" 2>/dev/null
    tmpfile=""
    rm -rf "$instance_slot" 2>/dev/null
    ralph_cleanup_worktree "$work_dir"
    [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null
    kill -9 0 2>/dev/null
    exit 1
  }

  # ─── Early exit for --once with no work (before titlebar clears screen) ─
  if [[ "$run_once" == "true" ]]; then
    local early_prs early_count
    early_prs=$(ralph_fetch_github_prs)
    early_count=$(echo "$early_prs" | jq 'length')
    if [[ "$early_count" -lt "$instance_num" ]]; then
      ralph_log "${agent_name} #$instance_num: No PRs needing fixes ($early_count found). Nothing to do."
      rm -rf "$instance_slot" 2>/dev/null
      exit 0
    fi
  fi

  ralph_titlebar_init

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    local pr_json pr_count
    pr_json=$(ralph_fetch_github_prs)
    pr_count=$(echo "$pr_json" | jq 'length')

    if [[ "$pr_count" -lt "$instance_num" ]]; then
      if [[ "$run_once" == "true" ]]; then
        ralph_log "${agent_name} #$instance_num: No PRs needing fixes ($pr_count found). Nothing to do."
        exit 0
      fi
      ralph_log "Not enough PRs for instance #$instance_num ($pr_count available). Sleeping ${poll_interval}s..."
      ralph_cooldown "$poll_interval" "${(U)agent_name} #$instance_num | Waiting" || die
      continue
    fi

    # Pick the PR for this instance (1-indexed instance, 0-indexed array)
    local target_pr
    target_pr=$(echo "$pr_json" | jq ".[$((instance_num - 1))]")

    iteration=$((iteration + 1))
    tmpfile=$(mktemp)

    ralph_titlebar_update "${(U)agent_name} #$instance_num | Iteration $iteration | PRs: $pr_count | $(date '+%H:%M:%S')"
    echo "------- ${(U)agent_name} #$instance_num ITERATION $iteration ($pr_count PRs) --------"

    setopt MONITOR
    {
      (
        (cd "$work_dir" && claude \
          --verbose \
          --print \
          --max-turns 100 \
          --output-format stream-json \
          --dangerously-skip-permissions \
          --append-system-prompt "$(cat "$prompt_file")" \
          "You are RALPH_${(U)agent_key}, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir). Fix this PR now:
$target_pr
Start with Step 1 — checkout the branch and assess what needs fixing.") \
        | grep --line-buffered '^{' \
        | tee "$tmpfile" \
        | jq --unbuffered -rj "$stream_text"
      ) </dev/null &
    } 2>/dev/null
    child_pid=$!
    unsetopt MONITOR
    wait $child_pid 2>/dev/null || true
    [[ $shutdown -eq 1 ]] && die
    kill -9 -$child_pid 2>/dev/null || true
    child_pid=""

    local result
    result=$(jq -r "$final_result" "$tmpfile")

    # Persist session log before deleting tmpfile
    local pr_number
    pr_number=$(echo "$target_pr" | jq -r '.number // empty')
    ralph_save_session_log "$tmpfile" "$agent_key" "$instance_num" "PR-${pr_number:-unknown}"

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
