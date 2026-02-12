# Ralph Agent Ecosystem

Ralph is a suite of autonomous agents that orchestrate Claude CLI for backlog-driven SDLC automation. Each agent acts as a specialized team member, picking up tasks from your backlog based on specific criteria.

## Install

```bash
git clone <repo-url> ralph
cd ralph
npm link
```

This installs all Ralph commands globally. Run them from any project directory.

To uninstall: `npm unlink -g ralph`

## Configuration

### Quick Start

```bash
cd your-project
ralph init          # Creates .ralphrc from template
# Edit .ralphrc with your credentials
ralph config        # Verify configuration
```

### `.ralphrc`

Ralph loads `.ralphrc` from the current working directory. This file sets your backlog provider and credentials:

```zsh
export RALPH_PROVIDER="jira"
export JIRA_EMAIL="you@example.com"
export JIRA_API_TOKEN="your-token"
export JIRA_BASE_URL="https://yourorg.atlassian.net"
export RALPH_POLL_INTERVAL=5
```

Alternatively, set these as environment variables in your shell profile.

## Commands

### Agent Loops

Each agent runs an infinite poll loop: check backlog for tasks, invoke Claude, sleep, repeat.

| Command           | Role          | Trigger                                                  |
| :---------------- | :------------ | :------------------------------------------------------- |
| `afk-planner`     | Product Owner | Description empty/TODO, or label `needs-planning`        |
| `afk-implementer` | Developer     | Status "To Do"/"In Progress", description filled         |
| `afk-reviewer`    | QA/Lead       | Status "In Review"                                       |
| `afk-tester`      | QA Engineer   | Label `needs-tests`, not Done                            |
| `afk-refactor`    | Architect     | Label `tech-debt`                                        |
| `afk-documenter`  | Tech Writer   | Status "Done", not yet documented                        |

### Utility Commands

| Command                | Description                                    |
| :--------------------- | :--------------------------------------------- |
| `afk-claude <N>`       | Run N iterations with the generic prompt        |
| `afk-claude-gated`     | Generic gated loop (configurable via `RALPH_CUSTOM_QUERY`) |
| `once-claude [prompt]`  | Single-run Claude session                      |
| `validate-routing`     | Check routing.json for overlaps/gaps/drift     |
| `ralph init`           | Create `.ralphrc` in current directory          |
| `ralph config`         | Show current configuration                      |
| `ralph version`        | Show version                                    |

### Running a Full Team

```bash
# Run each agent in a separate terminal tab:
afk-planner        # Tab 1
afk-implementer    # Tab 2
afk-reviewer       # Tab 3
afk-tester         # Tab 4
afk-refactor       # Tab 5
afk-documenter     # Tab 6
```

## Providers

Ralph abstracts the backlog system. Set `RALPH_PROVIDER` to switch providers.

### Supported Providers

- **jira** (default) — Jira Cloud via REST API

### Provider Architecture

Each provider consists of 3 files:

| File | Purpose |
| :--- | :------ |
| `lib/providers/<name>.sh` | Shell: `PROVIDER_ENV_VARS` array + `provider_check_tasks()` function |
| `providers/<name>/instructions.md` | Claude system prompt overlay with tool mappings |
| `providers/<name>/routing.json` | Queries and routing rules per agent |

### Adding a New Provider

To add support for GitHub Issues, Linear, etc.:

1. **`lib/providers/github.sh`** — Implement `PROVIDER_ENV_VARS` and `provider_check_tasks()`
2. **`providers/github/instructions.md`** — Map generic workflow concepts to provider-specific MCP tools
3. **`providers/github/routing.json`** — Provider-specific queries per agent

No changes to core lib, bin wrappers, or base prompts needed.

## Routing

All agent routing rules live in `providers/<provider>/routing.json` — the single source of truth for queries.

### Validating Routing

```bash
# Check for overlaps and gaps (simulates ~168 ticket states)
validate-routing

# Full matrix — see which agents match every simulated state
validate-routing --matrix

# Check query drift between routing.json and prompt files
validate-routing --check-prompts
```

When adding or modifying agent routing:
1. Update `routing.json` (both `jql` and `rules`)
2. Update the corresponding `prompts/*.md` query to match
3. Run `validate-routing` to verify no overlaps
4. Run `validate-routing --check-prompts` to verify no drift

## Labels

| Label             | Purpose                                              |
| :---------------- | :--------------------------------------------------- |
| `needs-planning`  | Ticket needs (re-)planning by the Planner agent      |
| `needs-tests`     | Ticket needs test coverage. Routed to Tester         |
| `tech-debt`       | Code is functional but needs refactoring. Routed to Refactorer |
| `ralph-blocked`   | Implementer hit a blocker it cannot resolve          |
| `ralph-failed`    | Build or test failure during implementation          |
| `needs-input`     | Planner needs human clarification on requirements    |
| `documented`      | Documenter has updated docs for this ticket          |

## Workflow

1.  **Planner** finds empty/TODO tickets (or `needs-planning`), adds specs, moves to **To Do**.
2.  **Implementer** picks up **To Do** (excludes `needs-tests`, `tech-debt`, `ralph-blocked`, `needs-planning`), writes code, moves to **In Review**.
3.  **Reviewer** checks code (excludes `needs-planning`, `needs-tests`, `tech-debt`):
    - **Approve**: Moves to **Done**.
    - **Reject**: Moves back to **In Progress** (Implementer re-picks).
    - **Needs Tests**: Adds `needs-tests` -> **To Do** (Tester picks up).
    - **Tech Debt**: Adds `tech-debt` -> **Done** (Refactorer picks up; Documenter waits).
4.  **Tester** picks up `needs-tests` (not Done), adds tests, removes `needs-tests`, moves to **In Review**.
    - If untestable: adds `tech-debt`, removes `needs-tests`, moves to **To Do** (escalates to Refactorer).
5.  **Refactorer** picks up `tech-debt`, refactors, removes `tech-debt`, moves to **In Review**.
6.  **Documenter** picks up **Done** items (excludes `tech-debt`, `documented`), updates docs, adds `documented` label.

## Project Structure

```
ralph/
├── bin/                          # Executable CLI commands
├── lib/
│   ├── ralph-core.sh             # Shared functions
│   ├── ralph-gated-loop.sh       # Parameterized backlog-gated loop
│   ├── ralph-iter-loop.sh        # Parameterized N-iteration loop
│   └── providers/
│       └── jira.sh               # Jira provider implementation
├── prompts/                      # Provider-agnostic workflow prompts
├── providers/
│   └── jira/
│       ├── instructions.md       # Jira MCP tool mappings
│       └── routing.json          # Jira queries + validation rules
├── package.json
├── .ralphrc.example
└── README.md
```
