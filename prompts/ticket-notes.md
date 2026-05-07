# TICKET NOTES — Extract per-ticket working memory

You are extracting **per-ticket working notes** from a Ralph agent's iteration log. These notes survive across iterations on the same ticket — they let the next iteration skip rediscovery.

This is **not** the same as `<learnings>` (which captures generalisations across all tickets, written elsewhere). This file is the ticket's working memory: paths, IDs, and progress that are useless on other tickets but invaluable on this one.

## Input
- The ticket key
- The current notes file (may be empty on first run)
- Stream-json output from the agent's last iteration on this ticket

## Task
Produce the **complete replacement** notes file. Do NOT append — output the full final set.

## What to capture
- **Paths/IDs discovered**: worktree subdir, app/package directory, key route files, env vars, test fixtures, database UUIDs, seeded user logins, etc.
- **Current state of work**: what's been done, what works, what doesn't, what was attempted and failed.
- **What the next iteration should attempt first**: the immediate next step, ideally with the exact command or selector.

## Rules
1. **Per-ticket facts only.** Things that are useful for *this ticket and no other.* Generic rules ("always run build before push") belong in learnings, not here — skip them.
2. Max **20 bullets**. Drop the least useful if you exceed it.
3. **Output an empty block** `<ticket_notes></ticket_notes>` when:
   - The iteration ended with `<promise>COMPLETE</promise>` (ticket is moving to In Review/Done — scratchpad no longer needed).
   - The iteration didn't actually work on this ticket (picked it up but ABORTed immediately, etc.).
4. If the iteration made progress but didn't finish, **carry forward** the still-relevant prior notes and add what was learned this iteration. Drop notes that are now stale (e.g. a path that was renamed).
5. Keep bullets concise — one line each. Concrete over abstract.

## Output format
Wrap output in a `<ticket_notes>` block:

```
<ticket_notes>
- app dir: apps/consolidated-hank
- route: src/app/(inspections)/[id]/builder/page.tsx
- test inspection UUID: 3d10c092-d60c-46b6-bc85-dc6e963f26c2
- inspector login: inspector@test.local / password
- progress: walked sections 1–3, photo upload OK, auto-save verified
- next: section 4 onward, then submit + write gap doc to docs/tracer-bullets/PRODUCT-896-web-checklist-gaps.md
</ticket_notes>
```

If the ticket is done or the iteration produced nothing useful for next time:

```
<ticket_notes>
</ticket_notes>
```
