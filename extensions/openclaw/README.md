# Ralph Agent Bridge — OpenClaw Plugin

Monitor and control Ralph agents from Telegram via OpenClaw.

## Features

- `/ralph` command in Telegram — check status, start/stop agents, view logs
- `openclaw ralph` CLI — same commands from terminal
- Background monitor — notifications on iteration complete/abort, agent start/stop

## Setup

### 1. Install dependencies

```bash
cd ~/Repositories/ralph/extensions/openclaw
npm install
```

### 2. Install the plugin

Use `--link` so the source directory is used directly (no copy — edits take effect immediately):

```bash
openclaw plugins install --link ~/Repositories/ralph/extensions/openclaw
```

This adds the plugin to `plugins.allow`, `plugins.entries`, and `plugins.load.paths` in `~/.openclaw/openclaw.json`.

### 3. Configure

Merge into `plugins.entries.ralph.config` in `~/.openclaw/openclaw.json`:

```jsonc
{
  "projectDir": "/path/to/your/project",   // CWD for ralph commands (must have .ralphrc)
  "chatId": "YOUR_TELEGRAM_CHAT_ID",        // required
  "threadId": 12345,                         // optional, for topic-based groups
  "accountId": "your-account-id",            // optional, multi-account Telegram setups
  "agents": ["planner", "implementer", "reviewer", "tester", "fixer"],
  "notifications": {
    "onComplete": true,
    "onAbort": true,
    "onStart": true,
    "onStop": true
  },
  "pollIntervalMs": 5000
}
```

### 4. Restart & verify

```bash
openclaw gateway restart
openclaw plugins doctor
openclaw ralph status
```

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/ralph` or `/ralph status` | Show agent status table |
| `/ralph start <agent>` | Start agent in `--afk` (continuous) mode |
| `/ralph once <agent>` | Start agent in `--once` mode |
| `/ralph stop <agent> [N]` | Stop agent instance (all instances if N omitted) |
| `/ralph log <agent> [N]` | Show last iteration summary (instance 1 if N omitted) |

## CLI Commands

Same subcommands via `openclaw ralph`:

```bash
openclaw ralph status
openclaw ralph start implementer
openclaw ralph once planner
openclaw ralph stop implementer 2
openclaw ralph log implementer
```

## Notifications

When the monitor service is running, you'll receive Telegram messages like:

```
▶ RALPH_PLANNER #1 started (PID 12345)

✓ RALPH_IMPLEMENTER #1 — COMPLETE
Task: PROD-42 | Iteration: 3
Added pagination to /api/users with cursor-based nav...

✗ RALPH_REVIEWER #1 — ABORT
Task: PROD-42 | Iteration: 2
Merge conflict in src/api/routes.ts...

■ RALPH_REVIEWER #1 stopped
```

## Config Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | boolean | `true` | Enable/disable the plugin |
| `projectDir` | string | **required** | Path to project with `.ralphrc` |
| `chatId` | string | **required** | Telegram chat ID for notifications |
| `threadId` | number | — | Telegram message thread (topic) ID |
| `accountId` | string | — | Telegram account ID (multi-account) |
| `agents` | string[] | `["planner","implementer","reviewer","tester","fixer"]` | Agents to monitor |
| `notifications.onComplete` | boolean | `true` | Notify on iteration complete |
| `notifications.onAbort` | boolean | `true` | Notify on iteration abort |
| `notifications.onStart` | boolean | `true` | Notify on agent start |
| `notifications.onStop` | boolean | `true` | Notify on agent stop |
| `pollIntervalMs` | number | `5000` | Monitor poll interval in ms |
