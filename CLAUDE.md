# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ralph Is

Ralph is a suite of autonomous agents that orchestrate Claude CLI for backlog-driven SDLC automation. It's a **pure shell project** (zsh/bash) — no build step, no transpilation, no test framework. Installed globally via `npm link`.

## Commands

```bash
npm link                        # Install globally
ralph planner --once            # Run one iteration of an agent
ralph implementer --afk         # Run agent in continuous poll loop (default)
ralph fixer --once              # GitHub PR fixer agent
ralph debug implementer         # Show last 200 lines of agent output
ralph debug implementer -f      # Live tail a running agent
ralph debug implementer 2 --raw # Raw JSON from instance 2
ralph validate --check-all      # Validate routing rules (run after routing changes)
ralph init                      # Create .ralphrc in CWD
ralph config                    # Show current config
```

## Architecture

### Two Loop Types

1. **Backlog-gated** (`lib/ralph-gated-loop.sh`) — polls a provider (Jira/Linear/GitHub Issues/GitHub Projects/file) for matching tasks. Used by: planner, implementer, reviewer, tester, refactor, documenter.
2. **GitHub-gated** (`lib/ralph-github-loop.sh`) — polls for open PRs with unresolved review threads. Used by: fixer.

Both loops: check for work → invoke `claude` with agent prompt + provider instructions → parse stream-json output → check for `<promise>COMPLETE</promise>` or `<promise>ABORT</promise>` → cooldown → repeat.

### Provider Abstraction

Each provider has 3 files:

| File | Purpose |
|:-----|:--------|
| `lib/providers/<name>.sh` | Exports `PROVIDER_ENV_VARS` array + `provider_check_tasks()` function |
| `providers/<name>/instructions.md` | System prompt overlay injected via `--append-system-prompt` |
| `providers/<name>/routing.json` | Single source of truth for agent queries + validation rules |

Adding a provider requires only these 3 files — no changes to core lib or bin wrappers.

### Agent Prompts (`prompts/*.md`)

Provider-agnostic workflow instructions. Structure: RULES → WORKFLOW (Load Context → Pick Task → Do Work → Update Backlog → Commit & Stop). Each prompt embeds the query from routing.json.

### Multi-Instance Support

Agents claim numbered slots in `/tmp/ralph-{agent}/{n}`. Instance number determines which task to pick (instance 1 picks task 1, instance 2 picks task 2, etc.). Stale PIDs are auto-cleaned.

## Shell Conventions

- `#!/bin/zsh` for all agent scripts (zsh can reliably kill running Claude subprocesses; bash cannot)
- `#!/bin/bash` only for `validate-routing-impl` (doesn't manage Claude processes)
- `realpath "$0"` resolves through npm symlinks to find `RALPH_HOME`
- `.ralphrc` is **sourced** (not parsed) — it's a shell script exporting env vars

## Routing Validation

After modifying `routing.json` or agent queries:

1. Update `providers/<provider>/routing.json` (both `query` and `rules`)
2. Update the corresponding `prompts/*.md` query to match
3. Run `ralph validate` (simulates ~168 ticket states, reports overlaps/gaps)
4. Run `ralph validate --check-prompts` (detects query drift between routing.json and prompts)
5. Run `ralph validate --check-loops` (checks self-loop risks)

## Claude Invocation Pattern

All agents invoke Claude identically:
```bash
claude --verbose --print --max-turns 100 --output-format stream-json \
  --dangerously-skip-permissions \
  --append-system-prompt "$(cat "$prompt_file")
$(cat "$provider_instructions")" \
  "You are RALPH_${agent}, instance $n. Execute your workflow now."
```

Output is piped through `grep --line-buffered '^{'` → `tee $tmpfile` → `jq --unbuffered` for streaming display, then the final result is extracted for promise detection.

## Key Workflow Rules (enforced in all agent prompts)

- ONE TASK per iteration — never batch
- BACKLOG IS TRUTH — always re-read before acting
- Agents must output `<promise>COMPLETE</promise>` on success or `<promise>ABORT</promise>` on failure
- Commit format: `RALPH_{AGENT}: {action} ({TASK-KEY})`
