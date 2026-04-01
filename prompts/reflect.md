# REFLECT — Extract learnings from agent session

You are analyzing a Ralph agent's session log to extract reusable learnings.

## Input
- Stream-json output from the agent's last iteration
- Current learnings file (may be empty on first run)

## Task
Produce the **complete replacement** learnings file. Do NOT append — output the full final set.

## Rules
1. Max **15 rules**. If you need to add one and are at 15, drop the least useful.
2. Each rule has a `(seen: N)` counter:
   - If a pattern from the current learnings recurs in this session, **increment** its counter.
   - If a current rule is NOT relevant to this session, **decrement** its counter.
   - Rules that reach `(seen: 0)` are **dropped**.
   - New rules start at `(seen: 1)`.
3. Focus on: wasted turns, tool misuse, prompt non-compliance, repeated errors, wrong assumptions, **operational shortcuts** (how to start servers, log in, navigate UI, run tests).
4. Rules must be **reusable across iterations** — no ticket keys or one-off facts, but project-specific operational knowledge (URLs, login steps, dev commands) is encouraged.
5. Merge similar rules rather than keeping duplicates.
6. Keep rules concise — one line each.

## Output format
Wrap output in a `<learnings>` block:

```
<learnings>
- (seen: 3) Always check PR status before pushing new commits
- (seen: 1) Use gh pr checks --json name,state,link — not conclusion or detailsUrl
</learnings>
```

If the session was clean with no mistakes or wasted effort, output an empty block:
```
<learnings>
</learnings>
```
