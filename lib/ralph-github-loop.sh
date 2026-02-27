#!/bin/zsh
# ralph-github-loop.sh — GitHub PR-gated AFK loop
#
# Usage: source this file, then call ralph_github_loop <agent_key> <agent_name>
# Unlike ralph-gated-loop.sh, this does NOT use a Jira provider.
# It gates on GitHub PRs needing attention.

# ─── Agent-specific dispatch helpers ─────────────────────────────────────────

ralph_github_fetch_for_agent() {
  case "$1" in
    fixer)  ralph_fetch_fixer_prs ;;
    merger) ralph_fetch_mergeable_prs ;;
    *)      ralph_fetch_fixer_prs ;;
  esac
}

ralph_github_initial_message() {
  local agent_key="$1" instance_num="$2" work_dir="$3" project_dir="$4" target_pr="$5"
  local worktree_context=""
  if [[ -n "${RALPH_WORKTREE_CONTEXT:-}" ]]; then
    worktree_context="
Worktree setup output (use this for ports, domains, and dev environment details):
$RALPH_WORKTREE_CONTEXT"
  fi
  case "$agent_key" in
    fixer)
      echo "You are RALPH_FIXER, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir). Fix this PR now:
$target_pr
Start with Step 1 — checkout the branch and assess what needs fixing.${worktree_context}"
      ;;
    merger)
      echo "You are RALPH_MERGER, instance $instance_num. Merge this PR now (squash + delete-branch):
$target_pr
Start with Step 1 — verify merge conditions."
      ;;
  esac
}

ralph_github_no_work_label() {
  case "$1" in
    fixer)  echo "fixes" ;;
    merger) echo "merges" ;;
    *)      echo "work" ;;
  esac
}

# ─── PR fetch functions ──────────────────────────────────────────────────────

ralph_fetch_fixer_prs() {
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

# Backward compat alias
ralph_fetch_github_prs() { ralph_fetch_fixer_prs; }

ralph_fetch_mergeable_prs() {
  # Fetch PRs labeled for merge that pass all conditions:
  # authored by @me, approved, mergeable (no conflicts), CI green.
  local repo label
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || repo=""
  if [[ -z "$repo" ]]; then
    echo "[]"
    return
  fi
  label="${RALPH_MERGE_LABEL:-ready-to-merge}"

  gh api graphql -f query="
    {
      search(query: \"is:pr is:open author:@me label:\\\"$label\\\" repo:$repo\", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            baseRefName
            isDraft
            mergeable
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup { state }
                }
              }
            }
          }
        }
      }
    }" --jq '[.data.search.nodes[] |
      select(.isDraft == false) |
      select(.mergeable == "MERGEABLE") |
      select(.commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS") |
      {number, title, url, headRefName, baseRefName}
    ]' 2>/dev/null || echo "[]"
}

ralph_check_github_prs() {
  ralph_fetch_fixer_prs | jq 'length'
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

  # ─── Session log ────────────────────────────────────────────────────────
  local session_log="$instance_slot/session.log"

  # ─── Worktree (only for agents that modify code) ───────────────────────
  local project_dir="$PWD"
  local work_dir uses_worktree=false
  case "$agent_key" in
    fixer|merger)
      work_dir=$(ralph_setup_worktree "$agent_key" "$instance_num")
      uses_worktree=true
      ;;
    *)
      work_dir="$PWD"
      ;;
  esac

  # Resolve paths
  local prompt_file poll_interval provider_instructions=""
  prompt_file="$(ralph_get_prompt "$agent_key")"
  poll_interval="$(ralph_get_poll_interval)"

  # Load provider instructions for agents that need Jira access (e.g. merger)
  case "$agent_key" in
    merger)
      source "$RALPH_HOME/lib/providers/${RALPH_PROVIDER}.sh"
      provider_instructions="$(ralph_get_provider_instructions)"
      ;;
  esac

  if [[ ! -f "$prompt_file" ]]; then
    ralph_error "Prompt not found: $prompt_file"
    exit 1
  fi

  # ─── jq filters ─────────────────────────────────────────────────────────
  ralph_get_jq_filters
  local stream_text="$RALPH_STREAM_FILTER"
  local final_result="$RALPH_RESULT_FILTER"

  # ─── State ──────────────────────────────────────────────────────────────
  local iteration=0
  local tmpfile=""
  local child_pid=""
  local shutdown=0
  local no_work_label
  no_work_label=$(ralph_github_no_work_label "$agent_key")

  trap 'shutdown=1; [[ -n "$child_pid" ]] && kill -INT -$child_pid 2>/dev/null' INT TERM HUP
  local last_task_key=""
  trap 'ralph_save_session_log "$session_log" "$agent_key" "$instance_num" "$last_task_key"; ralph_titlebar_cleanup; rm -f "$tmpfile" 2>/dev/null; rm -rf "$instance_slot" 2>/dev/null; [[ "$uses_worktree" == "true" ]] && ralph_cleanup_worktree "$work_dir"; [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null' EXIT

  die() {
    ralph_save_session_log "$session_log" "$agent_key" "$instance_num" "$last_task_key"
    ralph_titlebar_cleanup
    printf "\nShutting down.\n"
    rm -f "$tmpfile" 2>/dev/null
    tmpfile=""
    rm -rf "$instance_slot" 2>/dev/null
    [[ "$uses_worktree" == "true" ]] && ralph_cleanup_worktree "$work_dir"
    [[ -n "$child_pid" ]] && kill -9 -$child_pid 2>/dev/null
    exit 1
  }

  # ─── Early exit for --once with no work (before titlebar clears screen) ─
  if [[ "$run_once" == "true" ]]; then
    local early_prs early_count
    early_prs=$(ralph_github_fetch_for_agent "$agent_key")
    early_count=$(echo "$early_prs" | jq 'length')
    if [[ "$early_count" -lt "$instance_num" ]]; then
      ralph_log "${agent_name} #$instance_num: No PRs needing $no_work_label ($early_count found). Nothing to do."
      rm -rf "$instance_slot" 2>/dev/null
      exit 0
    fi
  fi

  ralph_titlebar_init

  # ─── Main loop ──────────────────────────────────────────────────────────
  while true; do
    local pr_json pr_count
    pr_json=$(ralph_github_fetch_for_agent "$agent_key")
    pr_count=$(echo "$pr_json" | jq 'length')

    if [[ "$pr_count" -lt "$instance_num" ]]; then
      if [[ "$run_once" == "true" ]]; then
        ralph_log "${agent_name} #$instance_num: No PRs needing $no_work_label ($pr_count found). Nothing to do."
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

    # Write iteration marker to session log
    echo '{"type":"_ralph_marker","iteration":'$iteration',"timestamp":"'$(date -Iseconds)'","prs":'$pr_count'}' >> "$session_log"

    local initial_message
    initial_message=$(ralph_github_initial_message "$agent_key" "$instance_num" "$work_dir" "$project_dir" "$target_pr")

    local max_iteration_seconds="${RALPH_MAX_ITERATION_SECONDS:-1800}"

    setopt MONITOR
    {
      (
        ralph_exec_llm "$agent_key" "$instance_num" "$work_dir" "$prompt_file" "$provider_instructions" "$initial_message" \
        | grep --line-buffered '^{' \
        | tee "$tmpfile" | tee -a "$session_log" \
        | jq --unbuffered -rj "$stream_text"
      ) </dev/null &
    } 2>/dev/null
    child_pid=$!
    unsetopt MONITOR

    # Watchdog: force-kill if Claude hangs after max_turns (e.g. orphaned dev servers)
    local watchdog_pid=""
    ( sleep "$max_iteration_seconds" && ralph_log "Iteration timeout (${max_iteration_seconds}s). Force-killing..." && kill -9 -$child_pid 2>/dev/null ) &
    watchdog_pid=$!

    wait $child_pid 2>/dev/null || true
    kill $watchdog_pid 2>/dev/null; wait $watchdog_pid 2>/dev/null || true
    watchdog_pid=""
    [[ $shutdown -eq 1 ]] && die
    kill -9 -$child_pid 2>/dev/null || true
    child_pid=""

    # Kill orphaned processes (dev servers, MCP servers) left in the worktree
    ralph_cleanup_worktree_processes "$work_dir"

    local result
    result=$(jq -r "$final_result" "$tmpfile" 2>/dev/null || true)
    last_task_key=$(ralph_extract_task_key "$tmpfile")

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
