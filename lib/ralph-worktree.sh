#!/bin/zsh
# ralph-worktree.sh — Git worktree lifecycle management

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

  # Serialize worktree creation — concurrent git worktree add races on .git/config
  local git_lock="/tmp/ralph-git-worktree.lock"
  while ! mkdir "$git_lock" 2>/dev/null; do sleep 0.5; done
  trap 'rmdir "$git_lock" 2>/dev/null' EXIT

  # Check for valid worktree (not just directory existence — stale dirs without .git happen)
  if [[ ! -d "$RALPH_WORKTREE_DIR" ]] || ! git -C "$RALPH_WORKTREE_DIR" rev-parse --git-dir &>/dev/null; then
    rm -rf "$RALPH_WORKTREE_DIR" 2>/dev/null || true
    local branch_name="ralph-workspace/${agent_key}-${instance_num}"
    # Remove stale worktree entry if git still tracks it
    git worktree prune 2>/dev/null || true
    # Delete stale branch if it exists but worktree is gone
    git branch -D "$branch_name" >/dev/null 2>&1 || true
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      # Branch still exists — likely checked out in main repo. Switch main repo away.
      local main_branch
      main_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"
      if [[ "$(git symbolic-ref --short HEAD 2>/dev/null)" == "$branch_name" ]]; then
        ralph_log "Main repo on workspace branch $branch_name — switching to $main_branch"
        git checkout "$main_branch" --quiet 2>/dev/null || true
        git branch -D "$branch_name" >/dev/null 2>&1 || true
      fi
    fi
    # Resolve the repo's default branch (e.g. develop, main)
    local default_ref="origin/HEAD"
    if ! git rev-parse --verify "$default_ref" &>/dev/null; then
      default_ref="HEAD"
    fi
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      # Branch persists (checked out elsewhere) — reuse it
      git worktree add "$RALPH_WORKTREE_DIR" "$branch_name" --quiet
    else
      git worktree add "$RALPH_WORKTREE_DIR" -b "$branch_name" "$default_ref" --quiet
    fi
  fi

  # Release git lock — worktree is created, safe for others now
  rmdir "$git_lock" 2>/dev/null || true
  trap - EXIT

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

  # Run project-specific worktree setup from its original location (not copied).
  # This avoids files being wiped by git checkout / reset --hard.
  # Priority: explicit RALPH_WORKTREE_SETUP > auto-detect in project overlay dir
  # Stdout is captured into RALPH_WORKTREE_CONTEXT for the agent; stderr passes through.
  local project_name="${RALPH_PROJECT:-$(basename "$PWD")}"
  local project_overlay="$HOME/.ralph/projects/$project_name"
  local setup_cmd="${RALPH_WORKTREE_SETUP:-}"
  if [[ -z "$setup_cmd" && -f "$project_overlay/scripts/worktree-setup.sh" ]]; then
    setup_cmd="bash \"$project_overlay/scripts/worktree-setup.sh\" \"$RALPH_WORKTREE_DIR\""
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
