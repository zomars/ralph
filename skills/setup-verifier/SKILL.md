---
name: setup-verifier
description: Scaffolds the per-project verifier-context.sh script that ralph's verifier agent reads when running staging-only Playwright checks. Run from inside the target project's repo root. Detects staging URL, test users, server log access, and writes ~/.ralph/projects/<project>/scripts/verifier-context.sh. Run before first use of the ralph verifier agent.
---

# Setup Verifier (per-project)

Scaffold the per-project context script that the **ralph verifier** agent reads at the start of every iteration. Without it, verifier has no idea what staging URL to test, what users to log in as, or how to fetch server logs.

This is a **prompt-driven skill, not a deterministic script**. Explore, present what you found, confirm with the user, then write.

## What this produces

A single executable shell script at:
```
~/.ralph/projects/<project>/scripts/verifier-context.sh
```

Whose stdout becomes the verifier agent's project context every iteration. The file is project-private — it lives outside the ralph repo (so it's not committed to ralph) and outside the target project repo (so it's not committed there either).

## Process

### 1. Explore

Read what exists in the current directory. Don't assume — observe.

- `git remote -v` — derive project name from the remote's repo segment (e.g., `myapp` from a `someorg/myapp.git` remote). If no remote, use `basename "$PWD"`.
- `~/.ralph/projects/<project>/scripts/verifier-context.sh` — already exists? Read it; offer diff/update path instead of overwrite.
- **Staging URL hints**:
  - `vercel.json`, `next.config.*`, `astro.config.*` — production URLs, deploy aliases
  - `.env*` files (especially `.env.production`, `.env.staging`) — `NEXT_PUBLIC_*_URL`, `*_BASE_URL`, `STAGING_URL`
  - `package.json` `scripts` (e.g., `"deploy:staging": "vercel --prod"`) and `homepage` field
  - `README.md`, `README*.md` — most projects mention staging URL in a setup section
  - If `gh` is configured and project has GitHub Actions, look at deploy workflow files for environment URLs
- **Test user credentials**:
  - `.env*` for credential-shaped vars (e.g., `TEST_EMAIL`, `TEST_PASSWORD`, `*_USER`, `*_PASSWORD`).
  - `e2e/`, `tests/e2e/`, `playwright/` — fixture files that hardcode test users
  - Seed scripts (`scripts/seed*.{ts,js,sql}`) that create test accounts
- **Server log sources** (detect by signal):
  - `package.json` deps: `@vercel/*`, `vercel` CLI presence (`command -v vercel`) → Vercel runtime logs
  - `posthog-*`, `posthog-js` deps OR `mcp__plugin_posthog_*` available → PostHog errors MCP
  - `@sentry/*` → Sentry CLI / dashboard
  - `@datadog/*`, `dd-trace` → Datadog
  - The project's `.mcp.json` — what MCP servers are already wired
  - `~/.claude/plugins/cache/` listings — what Claude plugins are available globally
- **Pre-flight smoke endpoint**:
  - Default: `GET /` of the staging URL
  - If the project exposes an obvious health endpoint (`/api/health`, `/healthz`, `/_health`), prefer it — survey `src/app/api/`, `src/pages/api/`, `app/api/` for `health` route.
- **Framework**: Next.js, Remix, Astro, Vite, etc. — use only to inform the smoke-endpoint default; doesn't drive other decisions.

### 2. Present findings, three sections, one at a time

Do **not** dump all three at once. Walk the user through each, get an answer, move on.

Each section starts with a one-line explainer (what this is, why verifier needs it). Then show what you detected and the proposed default. Ask the user to confirm or override.

#### Section A — Staging URL + smoke endpoint

> Explainer: The verifier agent runs Playwright against this URL to test deployed features. The smoke endpoint is a fast pre-flight check to detect staging outages — if it 5xxs, verifier aborts cleanly without marking tickets as broken.

Show:
- **Detected staging URL**: from <which file>. Confirm or override.
- **Detected smoke endpoint**: `GET <url>/` (default) or `GET <url>/api/health` if found. Confirm or override.

#### Section B — Test users

> Explainer: Most verifier checks need to log in. Embed the test credentials here so verifier doesn't have to grep them out of the repo every run. If credentials are sensitive, you can reference an env var instead of inlining (e.g., `<role>: $STAGING_<ROLE>_EMAIL / $STAGING_<ROLE>_PASSWORD` — verifier will resolve from its environment).

Show:
- Detected emails/passwords grouped by the role/persona names found in the project (whatever the codebase calls them: admin, customer, vendor, etc.).
- Per row: confirm to inline, swap for env var reference, or omit.

If nothing was detected, ask the user to type them. Don't fabricate.

#### Section C — Server log access

> Explainer: When a feature fails, verifier diagnoses by reading server-side logs. Each project ships logs differently — Vercel CLI, PostHog MCP, Sentry, etc. List the available sources here so the agent's prompt knows what to call.

Show detected sources with the command/MCP that fetches them. User picks which to declare (multi-select). Examples:

- `mcp__plugin_posthog_posthog__errors` — PostHog errors via MCP plugin
- `vercel logs <prod-url> --prod` — Vercel runtime logs via CLI (requires `vercel` linked to project)
- Sentry — provide instructions for `sentry-cli`
- "Other" — user describes in one paragraph

Also ask: any other MCP servers verifier should declare in `RALPH_VERIFIER_MCP_SERVERS=`? (This line is parsed by the loop. Default: `playwright`.)

### 3. Confirm with a draft

Show the full draft `verifier-context.sh` to the user. Format:

```bash
#!/bin/bash
# Verifier context for <project>. Read by ralph_setup_verifier_cwd at the start of every iteration.
# Stdout becomes the agent's prompt context. The RALPH_VERIFIER_MCP_SERVERS line is parsed by the loop.

cat <<'EOF'
## Staging
URL: <url>
Pre-flight smoke: GET <url><smoke-path> should return 200

## Test users
<role>: <email> / <password>
...

## Server logs
- <source 1 with how to access>
- <source 2>

## Conventions
<optional: known flakes, common gotchas — leave blank if none>
EOF
echo "RALPH_VERIFIER_MCP_SERVERS=<comma-separated MCP names>"
```

Let the user edit before committing. They might want to add convention notes, swap inlined creds for env vars, etc.

### 4. Write

Once approved:

```bash
mkdir -p ~/.ralph/projects/<project>/scripts/
cat > ~/.ralph/projects/<project>/scripts/verifier-context.sh <<'EOF'
<draft contents>
EOF
chmod +x ~/.ralph/projects/<project>/scripts/verifier-context.sh
```

If the file already exists with different content: show a diff and explicitly ask before overwriting. **Never silently overwrite.**

### 5. Print next steps

Print a short block:

```
✓ verifier-context.sh written to ~/.ralph/projects/<project>/scripts/

Next steps:
  1. Add the `needs-staging-test` label to a Jira ticket you want verified in staging.
  2. From this directory, run: ralph verifier --once
  3. Monitor: ralph debug verifier -f

Reminders:
  - Only humans should add `needs-staging-test` (planner/reviewer don't write this label in v1).
  - On PASS, verifier will swap the label for `staging-verified` and transition the ticket to Done.
  - On FAIL, it adds `staging-broken` and posts structured evidence — but does NOT change status.
  - On staging outage, it ABORTS without touching labels (the loop will retry).

If you need to update <project>'s .mcp.json to include log MCP servers (e.g., posthog plugin), do that separately — this skill doesn't modify project files.
```

## Notes

- This skill writes outside the target project repo (under `~/.ralph/projects/<project>/`). It does **not** modify any files in the project itself, including `.mcp.json` — those are the user's call.
- If the user is in a directory that doesn't look like a project root (no `git remote`, no `package.json`, etc.), confirm before proceeding. They might have `cd`'d to the wrong place.
- The script is shell — it can do anything. If the user has dynamic context (e.g., the latest deploy URL from Vercel API), suggest they make the script call `vercel ls --prod | head -1` or similar at runtime. Static text is fine for v1.
