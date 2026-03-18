#!/bin/zsh
# ralph-github-loop.sh — GitHub PR-gated AFK loop (thin wrapper over ralph-loop.sh)
#
# Usage: source this file, then call ralph_github_loop <agent_key> <agent_name>
# Unlike ralph-gated-loop.sh, this does NOT use a backlog provider.
# It gates on GitHub PRs needing attention.

source "$RALPH_HOME/lib/ralph-loop.sh"

# ─── PR fetch functions ──────────────────────────────────────────────────────

ralph_fetch_fixer_prs() {
  # Fetch PRs with unresolved review threads (catches both human and bot feedback).
  # Returns a JSON array of {number, title, url, headRefName} for PRs needing fixes.
  local repo
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || repo=""
  if [[ -z "$repo" ]]; then
    echo "[]"
    return
  fi

  local graphql_prs
  graphql_prs=$(gh api graphql -f query="
    {
      search(query: \"is:pr is:open author:@me repo:$repo\", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            isDraft
            mergeable
            reviewThreads(first: 100) {
              nodes { isResolved }
            }
            latestReviews(first: 10) {
              nodes { state submittedAt }
            }
            commits(last: 1) {
              nodes { commit { committedDate } }
            }
          }
        }
      }
    }" --jq '[.data.search.nodes[] |
      select(.isDraft == false) |
      { hasUnresolvedThreads: (.reviewThreads.nodes | map(select(.isResolved == false)) | length > 0),
        hasConflicts: (.mergeable == "CONFLICTING"),
        hasChangesRequested: (
          (.commits.nodes[0].commit.committedDate // "1970-01-01T00:00:00Z") as $lastCommit |
          [.latestReviews.nodes[] | select(.state == "CHANGES_REQUESTED" and .submittedAt > $lastCommit)] | length > 0
        )
      } as $flags |
      select($flags.hasUnresolvedThreads or $flags.hasConflicts or $flags.hasChangesRequested) |
      {number, title, url, headRefName, hasConflicts: $flags.hasConflicts}
    ]' 2>/dev/null) || graphql_prs="[]"

  echo "$graphql_prs"
}

# Backward compat alias
ralph_fetch_github_prs() { ralph_fetch_fixer_prs; }

ralph_fetch_mergeable_prs() {
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
            reviewThreads(first: 100) {
              nodes { isResolved }
            }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 100) {
                      nodes {
                        ... on CheckRun { status conclusion }
                        ... on StatusContext { state }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }" --jq '[.data.search.nodes[] |
      select(.isDraft == false) |
      select(.mergeable == "MERGEABLE") |
      select([.reviewThreads.nodes[] | select(.isResolved == false)] | length == 0) |
      (.commits.nodes[0].commit.statusCheckRollup) as $rollup |
      select($rollup.state == "SUCCESS") |
      select([$rollup.contexts.nodes[] |
        select(.status != null and .status != "COMPLETED"),
        select(.state != null and .state != "SUCCESS" and .state != "NEUTRAL")
      ] | length == 0) |
      {number, title, url, headRefName, baseRefName}
    ]' 2>/dev/null || echo "[]"
}

ralph_check_github_prs() {
  ralph_fetch_fixer_prs | jq 'length'
}

# ─── Agent-specific dispatch helpers ─────────────────────────────────────────

_ralph_github_fetch_for_agent() {
  case "$1" in
    fixer)  ralph_fetch_fixer_prs ;;
    merger) ralph_fetch_mergeable_prs ;;
    *)      ralph_fetch_fixer_prs ;;
  esac
}

_ralph_github_initial_message() {
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

_ralph_github_no_work_label() {
  case "$1" in
    fixer)  echo "fixes" ;;
    merger) echo "merges" ;;
    *)      echo "work" ;;
  esac
}

# ─── Loop entry points ───────────────────────────────────────────────────────

ralph_github_loop_once() {
  ralph_github_loop "$1" "$2" 1
}

ralph_github_loop() {
  local _agent_key="$1"
  local _agent_name="$2"
  local _max_iterations="${3:-0}"

  # ─── Callbacks ──────────────────────────────────────────────────────────

  loop_init() {
    # Validate gh CLI
    if ! command -v gh &>/dev/null; then
      ralph_error "gh CLI is not installed. Install it: https://cli.github.com/"
      exit 1
    fi
    if ! gh auth status &>/dev/null; then
      ralph_error "gh CLI is not authenticated. Run: gh auth login"
      exit 1
    fi

    # Load provider for agents that need backlog access (e.g. merger)
    case "$_agent_key" in
      merger)
        ralph_load_provider
        ;;
    esac
  }

  loop_uses_worktree() {
    case "$_agent_key" in
      fixer|merger) echo "true" ;;
      *)            echo "false" ;;
    esac
  }

  loop_no_work_label() {
    _ralph_github_no_work_label "$_agent_key"
  }

  loop_fetch_work() {
    _ralph_github_fetch_for_agent "$_agent_key" > "$LOOP_WORK_FILE"
  }

  loop_count_work() {
    jq 'length' "$LOOP_WORK_FILE"
  }

  loop_pick_work() {
    # Pick the PR for this instance (1-indexed instance, 0-indexed array)
    LOOP_TASK_KEY=$(jq -r ".[$((instance_num - 1))].number // empty" "$LOOP_WORK_FILE")
    [[ -z "$LOOP_TASK_KEY" ]] && return 1
    local pr_count
    pr_count=$(loop_count_work)
    LOOP_TASK_DISPLAY="PRs: $pr_count"
    return 0
  }

  loop_build_context() {
    local target_pr
    target_pr=$(jq ".[$((instance_num - 1))]" "$LOOP_WORK_FILE")
    local provider_instructions=""
    case "$_agent_key" in
      merger) provider_instructions="$(ralph_get_provider_instructions)" ;;
    esac
    _ralph_github_initial_message "$_agent_key" "$instance_num" "$work_dir" "$project_dir" "$target_pr"
  }

  # ─── Run ────────────────────────────────────────────────────────────────

  ralph_run_loop "$_agent_key" "$_agent_name" "$_max_iterations"
}
