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
      search(query: \"is:pr is:open author:@me repo:$repo -label:blocked\", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            isDraft
            mergeable
            reviewDecision
            reviewThreads(first: 100) {
              nodes { isResolved }
            }
            latestReviews(first: 10) {
              nodes { state submittedAt }
            }
            commits(last: 1) {
              nodes {
                commit {
                  committedDate
                  statusCheckRollup {
                    state
                    contexts(first: 100) {
                      nodes {
                        ... on CheckRun { name status conclusion }
                        ... on StatusContext { context state }
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
      { hasUnresolvedThreads: (.reviewThreads.nodes | map(select(.isResolved == false)) | length > 0),
        hasConflicts: (.mergeable == "CONFLICTING"),
        hasChangesRequested: (
          (.commits.nodes[0].commit.committedDate // "1970-01-01T00:00:00Z") as $lastCommit |
          [.latestReviews.nodes[] | select(.state == "CHANGES_REQUESTED" and .submittedAt > $lastCommit)] | length > 0
        ),
        hasCIFailure: (
          [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[] |
            select((.conclusion // null) == "FAILURE")] | length > 0
        ),
        isAwaitingReview: (.reviewDecision == "REVIEW_REQUIRED"),
        needsDismissal: (
          (.reviewDecision == "CHANGES_REQUESTED") and
          (.reviewThreads.nodes | map(select(.isResolved == false)) | length == 0) and
          ((.commits.nodes[0].commit.committedDate // "1970-01-01T00:00:00Z") as $lastCommit |
            [.latestReviews.nodes[] | select(.state == "CHANGES_REQUESTED" and .submittedAt > $lastCommit)] | length == 0)
        )
      } as $flags |
      select(
        ($flags.hasUnresolvedThreads or $flags.hasConflicts or $flags.hasChangesRequested or $flags.hasCIFailure or $flags.needsDismissal)
        and ($flags.isAwaitingReview | not)
      ) |
      {number, title, url, headRefName, hasConflicts: $flags.hasConflicts, hasCIFailure: $flags.hasCIFailure, needsDismissal: $flags.needsDismissal}
    ]' 2>/dev/null) || graphql_prs="[]"

  echo "$graphql_prs"
}

# Backward compat alias
ralph_fetch_github_prs() { ralph_fetch_fixer_prs; }

ralph_fetch_mergeable_prs() {
  local repo
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || repo=""
  if [[ -z "$repo" ]]; then
    echo "[]"
    return
  fi
  gh api graphql -f query="
    {
      search(query: \"is:pr is:open author:@me repo:$repo -label:blocked\", type: ISSUE, first: 50) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            baseRefName
            isDraft
            mergeable
            reviewDecision
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
      select(.reviewDecision == "APPROVED") |
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
  local default_branch
  default_branch=$(git -C "$work_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || default_branch=""
  local branch_override=""
  if [[ -n "$default_branch" ]]; then
    branch_override="
The repository default branch is \`$default_branch\` (NOT \`main\` unless that matches). Use \`origin/$default_branch\` when creating feature branches."
  fi
  case "$agent_key" in
    fixer)
      echo "You are RALPH_FIXER, instance $instance_num. Your worktree is: $work_dir (project root: $project_dir).${branch_override} Fix this PR now:
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

# ─── Stuck review fixer (no Claude needed) ───────────────────────────────────

_ralph_fix_stuck_review() {
  local pr_number="$1"
  local repo
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || return 1
  local owner="${repo%%/*}"
  local name="${repo##*/}"

  ralph_log "PR #$pr_number: reviewDecision stuck at CHANGES_REQUESTED — fixing directly"

  # 1. Dismiss any CHANGES_REQUESTED reviews that still exist
  local review_ids
  review_ids=$(gh api "repos/$owner/$name/pulls/$pr_number/reviews" \
    --jq '[.[] | select(.state == "CHANGES_REQUESTED") | .id]' 2>/dev/null) || review_ids="[]"

  local dismissed=false
  for rid in $(echo "$review_ids" | jq -r '.[]'); do
    gh api -X PUT "repos/$owner/$name/pulls/$pr_number/reviews/$rid/dismissals" \
      -f message="All feedback addressed, threads resolved" 2>/dev/null && dismissed=true
  done

  if [[ "$dismissed" == "true" ]]; then
    ralph_log "PR #$pr_number: Dismissed stale reviews"
    return 0
  fi

  # 2. No reviews to dismiss — push empty commit via API to force GitHub to re-evaluate reviewDecision
  local head_sha
  head_sha=$(gh api "repos/$owner/$name/pulls/$pr_number" --jq '.head.sha' 2>/dev/null) || head_sha=""
  local head_ref
  head_ref=$(gh api "repos/$owner/$name/pulls/$pr_number" --jq '.head.ref' 2>/dev/null) || head_ref=""
  if [[ -n "$head_sha" && -n "$head_ref" ]]; then
    ralph_log "PR #$pr_number: No dismissable reviews — pushing empty commit to reset reviewDecision"
    # Create a new commit with same tree (empty commit) via Git API
    local new_sha
    local tree_sha
    tree_sha=$(gh api "repos/$owner/$name/git/commits/$head_sha" --jq '.tree.sha' 2>/dev/null) || tree_sha=""
    if [[ -n "$tree_sha" ]]; then
      new_sha=$(gh api "repos/$owner/$name/git/commits" \
        -f "message=chore: reset stale review state" \
        -f "tree=$tree_sha" \
        -f "parents[]=$head_sha" \
        --jq '.sha' 2>/dev/null) || new_sha=""
      if [[ -n "$new_sha" ]]; then
        gh api -X PATCH "repos/$owner/$name/git/refs/heads/$head_ref" \
          -f "sha=$new_sha" 2>/dev/null
        ralph_log "PR #$pr_number: Empty commit pushed — reviewDecision should reset"
        return 0
      fi
    fi
  fi

  # 3. Nothing worked — convert to draft to prevent looping
  ralph_log "PR #$pr_number: Cannot fix stuck review — converting to draft"
  gh pr ready "$pr_number" --undo 2>/dev/null
  gh pr comment "$pr_number" -b "RALPH_FIXER: Converted to draft — reviewDecision stuck at CHANGES_REQUESTED with no dismissable reviews. Mark as ready for review after human intervention." 2>/dev/null
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
    local idx=$(( instance_num - 1 ))
    LOOP_TASK_KEY=$(jq -r ".[$idx].number // empty" "$LOOP_WORK_FILE")
    [[ -z "$LOOP_TASK_KEY" ]] && return 1

    # Handle stuck reviewDecision directly — no need to invoke Claude
    local needs_dismissal
    needs_dismissal=$(jq -r ".[$idx].needsDismissal // false" "$LOOP_WORK_FILE")
    if [[ "$needs_dismissal" == "true" ]]; then
      _ralph_fix_stuck_review "$LOOP_TASK_KEY"
      # Skip this iteration — let next poll see the updated state
      return 1
    fi

    local pr_count
    pr_count=$(loop_count_work)
    LOOP_TASK_DISPLAY="PR #$LOOP_TASK_KEY ($pr_count queued)"
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
