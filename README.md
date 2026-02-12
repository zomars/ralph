# Ralph Agent Ecosystem

Ralph is a suite of autonomous agents designed to handle different stages of the software development lifecycle. Each agent acts as a specialized team member, picking up tasks from JIRA based on specific criteria.

## The Agents

| Agent           | Script                 | Role          | Trigger                                                                      | Excludes Labels                                            |
| :-------------- | :--------------------- | :------------ | :--------------------------------------------------------------------------- | :--------------------------------------------------------- |
| **Planner**     | `./afk-planner.sh`     | Product Owner | Description empty/TODO, or label `needs-planning`. Not Done.                 | —                                                          |
| **Implementer** | `./afk-implementer.sh` | Developer     | Status "To Do"/"In Progress", description filled.                            | `needs-tests`, `tech-debt`, `ralph-blocked`, `needs-planning` |
| **Reviewer**    | `./afk-reviewer.sh`    | QA/Lead       | Status "In Review".                                                          | `needs-planning`, `needs-tests`, `tech-debt`               |
| **Tester**      | `./afk-tester.sh`      | QA Engineer   | Label `needs-tests`. Not Done.                                               | `needs-planning`                                           |
| **Refactorer**  | `./afk-refactor.sh`    | Architect     | Label `tech-debt`.                                                           | `needs-planning`                                           |
| **Documenter**  | `./afk-documenter.sh`  | Tech Writer   | Status "Done".                                                               | `documented`, `tech-debt`                                  |

## Routing Config

All agent routing rules live in **`routing.json`** — the single source of truth for JQL queries. Shell scripts read their JQL from this file via `jq`, and the validator checks for overlaps and drift.

### `routing.json` Structure

- **`statuses`** / **`labels`**: All known values (used by the validator for simulation)
- **`agents.<key>.jql`**: The canonical JQL string (consumed by shell scripts via `jq -r`)
- **`agents.<key>.rules`**: Structured decomposition of the JQL (used by the validator to simulate ticket matching)
- **`agents.<key>.script`** / **`agents.<key>.prompt`**: File references for drift checking

### Validating Routing

```bash
# Check for overlaps and gaps (simulates ~168 ticket states)
./ralph/validate-routing.sh

# Full matrix — see which agents match every simulated state
./ralph/validate-routing.sh --matrix

# Check JQL drift between routing.json and prompt markdown files
./ralph/validate-routing.sh --check-prompts
```

When adding or modifying agent routing:
1. Update `routing.json` (both `jql` and `rules`)
2. Update the corresponding `prompt-*.md` JQL to match
3. Run `./ralph/validate-routing.sh` to verify no overlaps
4. Run `./ralph/validate-routing.sh --check-prompts` to verify no drift

## Getting Started

1.  **Configure Environment**:
    Ensure you have the following environment variables set (or in your `.zshrc`):
    - `JIRA_EMAIL`
    - `JIRA_API_TOKEN`
    - `JIRA_BASE_URL`
    - `RALPH_POLL_INTERVAL` (Optional, default 300s)

2.  **Run the Agents**:
    To simulate a full team, run each agent in a separate terminal tab:

    ```bash
    # Tab 1: Planner
    ./ralph/afk-planner.sh

    # Tab 2: Implementer
    ./ralph/afk-implementer.sh

    # Tab 3: Reviewer
    ./ralph/afk-reviewer.sh

    # Tab 4: Specialists (can rotate or run multiple)
    ./ralph/afk-tester.sh
    ```

## Labels

| Label             | Purpose                                              |
| :---------------- | :--------------------------------------------------- |
| `needs-planning`  | Ticket needs (re-)planning by the Planner agent.     |
| `needs-tests`     | Ticket needs test coverage. Routed to Tester.        |
| `tech-debt`       | Code is functional but needs refactoring. Routed to Refactorer. |
| `ralph-blocked`   | Implementer hit a blocker it cannot resolve.         |
| `ralph-failed`    | Build or test failure during implementation.         |
| `needs-input`     | Planner needs human clarification on requirements.   |
| `documented`      | Documenter has updated docs for this ticket.         |

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
