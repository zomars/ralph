#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { marked } from "marked";

const execFileAsync = promisify(execFile);

// ── Config ──────────────────────────────────────────────────────────────────

const BASE_URL = process.env.JIRA_BASE_URL?.replace(/\/$/, "");
const EMAIL = process.env.JIRA_EMAIL;
const TOKEN = process.env.JIRA_API_TOKEN;
const AGENT_KEY = process.env.RALPH_AGENT_KEY || "";
const DRY_RUN = process.argv.includes("--dry-run");

if (!BASE_URL || !EMAIL || !TOKEN) {
  console.error(
    "Missing required env vars: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN"
  );
  process.exit(1);
}

const AUTH = Buffer.from(`${EMAIL}:${TOKEN}`).toString("base64");

// ── Jira HTTP helper ────────────────────────────────────────────────────────

async function jira(method, path, body) {
  if (DRY_RUN) {
    console.error(
      `[dry-run] ${method} ${path}`,
      body ? JSON.stringify(body, null, 2) : ""
    );
    return { _dryRun: true };
  }

  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: {
      Authorization: `Basic ${AUTH}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });

  const text = await res.text();
  if (!res.ok) throw new Error(`Jira ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

// ── gh CLI helper ───────────────────────────────────────────────────────────

async function gh(...args) {
  if (DRY_RUN) {
    console.error(`[dry-run] gh ${args.join(" ")}`);
    return "";
  }
  const { stdout } = await execFileAsync("gh", args, {
    maxBuffer: 10 * 1024 * 1024,
    timeout: 60_000,
  });
  return stdout.trim();
}

async function ghJson(...args) {
  const raw = await gh(...args);
  return raw ? JSON.parse(raw) : null;
}

// ── Jira helpers ────────────────────────────────────────────────────────────

/** Append a label to a Jira issue (read-modify-write). */
async function jiraAddLabel(issueKey, label) {
  const issue = await jira("GET", `/rest/api/3/issue/${issueKey}?fields=labels`);
  const current = (issue.fields?.labels || []).map((l) =>
    typeof l === "object" ? l.name : l
  );
  if (current.includes(label)) return current;
  const updated = [...current, label];
  await jira("PUT", `/rest/api/3/issue/${issueKey}`, {
    fields: { labels: updated },
  });
  return updated;
}

/** Remove a label from a Jira issue (read-modify-write). */
async function jiraRemoveLabel(issueKey, label) {
  const issue = await jira("GET", `/rest/api/3/issue/${issueKey}?fields=labels`);
  const current = (issue.fields?.labels || []).map((l) =>
    typeof l === "object" ? l.name : l
  );
  const updated = current.filter((l) => l !== label);
  if (updated.length === current.length) return current;
  await jira("PUT", `/rest/api/3/issue/${issueKey}`, {
    fields: { labels: updated },
  });
  return updated;
}

/** Transition a Jira issue to a target status by name. */
async function jiraTransitionTo(issueKey, targetStatus) {
  const { transitions } = await jira(
    "GET",
    `/rest/api/3/issue/${issueKey}/transitions`
  );
  const match = transitions.find(
    (t) => t.name.toLowerCase() === targetStatus.toLowerCase()
  );
  if (!match) {
    throw new Error(
      `No transition to "${targetStatus}" for ${issueKey}. Available: ${transitions.map((t) => t.name).join(", ")}`
    );
  }
  await jira("POST", `/rest/api/3/issue/${issueKey}/transitions`, {
    transition: { id: match.id },
  });
}

// ── GitHub helpers ──────────────────────────────────────────────────────────

/** Fetch unresolved review thread count for a PR via GraphQL. */
async function ghUnresolvedThreadCount(prNumber) {
  const repo = await getRepo();
  const raw = await gh(
    "api",
    "graphql",
    "-f",
    `query={
      repository(owner: "${repo.owner}", name: "${repo.name}") {
        pullRequest(number: ${prNumber}) {
          reviewThreads(first: 100) {
            nodes { isResolved }
          }
        }
      }
    }`,
    "--jq",
    "[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length"
  );
  return parseInt(raw || "0", 10);
}

/** Cached owner/repo. Resolved lazily on first use. */
let _repo = null;
async function getRepo() {
  if (!_repo) {
    const raw = await gh(
      "repo",
      "view",
      "--json",
      "nameWithOwner",
      "--jq",
      ".nameWithOwner"
    );
    if (!raw) throw new Error("Cannot detect repo — is gh authenticated?");
    const [owner, name] = raw.split("/");
    _repo = { owner, name, full: raw };
  }
  return _repo;
}

/** Get the repo's default branch name. */
async function getDefaultBranch() {
  const raw = await gh(
    "repo",
    "view",
    "--json",
    "defaultBranchRef",
    "--jq",
    ".defaultBranchRef.name"
  );
  return raw || "main";
}

/** Check if a remote branch exists. */
async function branchExists(branchName) {
  try {
    const repo = await getRepo();
    await gh("api", `repos/${repo.owner}/${repo.name}/branches/${branchName}`);
    return true;
  } catch {
    return false;
  }
}

// ── Markdown → ADF ──────────────────────────────────────────────────────────

function markdownToAdf(md) {
  const tokens = marked.lexer(md);
  const content = tokens.flatMap(blockToAdf).filter(Boolean);
  return {
    version: 1,
    type: "doc",
    content: content.length
      ? content
      : [{ type: "paragraph", content: [txt("")] }],
  };
}

function blockToAdf(token) {
  switch (token.type) {
    case "heading":
      return {
        type: "heading",
        attrs: { level: token.depth },
        content: inlineToAdf(token.tokens),
      };

    case "paragraph": {
      const imgs = token.tokens.filter((t) => t.type === "image");
      const rest = token.tokens.filter(
        (t) => t.type !== "image" && !(t.type === "text" && !t.raw.trim())
      );
      if (imgs.length > 0 && rest.length === 0) {
        return imgs.map((img) => ({
          type: "mediaSingle",
          attrs: { layout: "center" },
          content: [
            { type: "media", attrs: { type: "external", url: img.href } },
          ],
        }));
      }
      return { type: "paragraph", content: inlineToAdf(token.tokens) };
    }

    case "code":
      return {
        type: "codeBlock",
        ...(token.lang ? { attrs: { language: token.lang } } : {}),
        content: [txt(token.text)],
      };

    case "list":
      return {
        type: token.ordered ? "orderedList" : "bulletList",
        content: token.items.map((item) => ({
          type: "listItem",
          content: listItemContent(item),
        })),
      };

    case "blockquote":
      return {
        type: "blockquote",
        content: token.tokens.flatMap(blockToAdf).filter(Boolean),
      };

    case "hr":
      return { type: "rule" };

    case "table": {
      const rows = [];
      if (token.header?.length) {
        rows.push({
          type: "tableRow",
          content: token.header.map((cell) => ({
            type: "tableHeader",
            content: [
              { type: "paragraph", content: inlineToAdf(cell.tokens) },
            ],
          })),
        });
      }
      for (const row of token.rows || []) {
        rows.push({
          type: "tableRow",
          content: row.map((cell) => ({
            type: "tableCell",
            content: [
              { type: "paragraph", content: inlineToAdf(cell.tokens) },
            ],
          })),
        });
      }
      return { type: "table", content: rows };
    }

    case "space":
      return null;

    default:
      if (token.tokens) {
        return { type: "paragraph", content: inlineToAdf(token.tokens) };
      }
      if (token.text) {
        return { type: "paragraph", content: [txt(token.text)] };
      }
      return null;
  }
}

function listItemContent(item) {
  return item.tokens
    .flatMap((t) => {
      if (t.type === "text" && t.tokens) {
        return { type: "paragraph", content: inlineToAdf(t.tokens) };
      }
      return blockToAdf(t);
    })
    .filter(Boolean);
}

function inlineToAdf(tokens, marks = []) {
  if (!tokens?.length) return [txt("")];
  const nodes = [];
  for (const t of tokens) {
    switch (t.type) {
      case "text":
        if (t.tokens) {
          nodes.push(...inlineToAdf(t.tokens, marks));
        } else {
          nodes.push(txt(t.text, marks));
        }
        break;
      case "strong":
        nodes.push(...inlineToAdf(t.tokens, [...marks, { type: "strong" }]));
        break;
      case "em":
        nodes.push(...inlineToAdf(t.tokens, [...marks, { type: "em" }]));
        break;
      case "del":
        nodes.push(...inlineToAdf(t.tokens, [...marks, { type: "strike" }]));
        break;
      case "codespan":
        nodes.push(txt(t.text, [...marks, { type: "code" }]));
        break;
      case "link":
        nodes.push(
          ...inlineToAdf(t.tokens, [
            ...marks,
            { type: "link", attrs: { href: t.href } },
          ])
        );
        break;
      case "image":
        nodes.push(
          txt(t.text || t.href, [
            ...marks,
            { type: "link", attrs: { href: t.href } },
          ])
        );
        break;
      case "br":
        nodes.push({ type: "hardBreak" });
        break;
      case "escape":
        nodes.push(txt(t.text, marks));
        break;
      default:
        if (t.raw) nodes.push(txt(t.raw, marks));
        break;
    }
  }
  return nodes.length ? nodes : [txt("")];
}

function txt(text, marks = []) {
  const node = { type: "text", text };
  if (marks.length) node.marks = marks;
  return node;
}

// ── Response helpers ────────────────────────────────────────────────────────

function ok(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function err(msg) {
  return { content: [{ type: "text", text: msg }], isError: true };
}

// ── MCP Server ──────────────────────────────────────────────────────────────

const server = new McpServer({
  name: "ralph",
  version: "2.0.0",
});

// ── Jira Tools (always registered) ──────────────────────────────────────────

server.tool(
  "searchJiraIssuesUsingJql",
  "Search Jira issues using JQL",
  {
    jql: z.string().describe("JQL query string"),
    maxResults: z
      .number()
      .optional()
      .default(10)
      .describe("Max results (default 10, max 100)"),
    fields: z.array(z.string()).optional().describe("Fields to return"),
  },
  async ({ jql, maxResults, fields }) => {
    try {
      const body = { jql, maxResults: Math.min(maxResults ?? 10, 100) };
      if (fields?.length) body.fields = fields;
      return ok(await jira("POST", "/rest/api/3/search/jql", body));
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "getJiraIssue",
  "Get a Jira issue by key or ID",
  {
    issueIdOrKey: z
      .string()
      .describe("Issue key (e.g. PROJ-123) or numeric ID"),
    fields: z.array(z.string()).optional().describe("Fields to return"),
  },
  async ({ issueIdOrKey, fields }) => {
    try {
      const qs = fields?.length ? `?fields=${fields.join(",")}` : "";
      return ok(await jira("GET", `/rest/api/3/issue/${issueIdOrKey}${qs}`));
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "editJiraIssue",
  "Update fields on a Jira issue. Description accepts markdown (converted to ADF automatically).",
  {
    issueIdOrKey: z.string().describe("Issue key or ID"),
    fields: z
      .record(z.string(), z.any())
      .describe("Fields to update (description accepts markdown)"),
  },
  async ({ issueIdOrKey, fields }) => {
    try {
      if (typeof fields.description === "string") {
        fields.description = markdownToAdf(fields.description);
      }
      await jira("PUT", `/rest/api/3/issue/${issueIdOrKey}`, { fields });
      return ok({ success: true, key: issueIdOrKey });
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "addCommentToJiraIssue",
  "Add a comment to a Jira issue. Comment body accepts markdown.",
  {
    issueIdOrKey: z.string().describe("Issue key or ID"),
    commentBody: z.string().describe("Comment text in markdown"),
  },
  async ({ issueIdOrKey, commentBody }) => {
    try {
      return ok(
        await jira("POST", `/rest/api/3/issue/${issueIdOrKey}/comment`, {
          body: markdownToAdf(commentBody),
        })
      );
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "getTransitionsForJiraIssue",
  "Get available status transitions for a Jira issue",
  {
    issueIdOrKey: z.string().describe("Issue key or ID"),
  },
  async ({ issueIdOrKey }) => {
    try {
      return ok(
        await jira("GET", `/rest/api/3/issue/${issueIdOrKey}/transitions`)
      );
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "transitionJiraIssue",
  "Transition a Jira issue to a new status",
  {
    issueIdOrKey: z.string().describe("Issue key or ID"),
    transition: z
      .object({ id: z.string().describe("Transition ID") })
      .describe("Transition object with id from getTransitionsForJiraIssue"),
  },
  async ({ issueIdOrKey, transition }) => {
    try {
      await jira("POST", `/rest/api/3/issue/${issueIdOrKey}/transitions`, {
        transition,
      });
      return ok({ success: true, key: issueIdOrKey });
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "createIssueLink",
  'Create a link between two Jira issues (e.g. "Blocks")',
  {
    linkType: z.string().describe('Link type name (e.g. "Blocks")'),
    outwardIssueKey: z
      .string()
      .describe("The issue that blocks/causes/etc."),
    inwardIssueKey: z
      .string()
      .describe("The issue that is blocked by/caused by/etc."),
  },
  async ({ linkType, outwardIssueKey, inwardIssueKey }) => {
    try {
      await jira("POST", "/rest/api/3/issueLink", {
        type: { name: linkType },
        outwardIssue: { key: outwardIssueKey },
        inwardIssue: { key: inwardIssueKey },
      });
      return ok({
        success: true,
        link: `${outwardIssueKey} --[${linkType}]--> ${inwardIssueKey}`,
      });
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "createJiraIssue",
  "Create a new Jira issue (e.g. subtask, story, task). Description accepts markdown.",
  {
    projectKey: z.string().describe("Project key (e.g. PROJ)"),
    issueTypeName: z
      .string()
      .describe('Issue type name (e.g. "Sub-task", "Task", "Story")'),
    summary: z.string().describe("Issue summary/title"),
    description: z.string().optional().describe("Description in markdown"),
    parentKey: z
      .string()
      .optional()
      .describe("Parent issue key for subtasks (e.g. PROJ-123)"),
    labels: z.array(z.string()).optional().describe("Labels to apply"),
  },
  async ({
    projectKey,
    issueTypeName,
    summary,
    description,
    parentKey,
    labels,
  }) => {
    try {
      const fields = {
        project: { key: projectKey },
        issuetype: { name: issueTypeName },
        summary,
      };
      if (description) fields.description = markdownToAdf(description);
      if (parentKey) fields.parent = { key: parentKey };
      if (labels?.length) fields.labels = labels;
      const res = await jira("POST", "/rest/api/3/issue", { fields });
      return ok({ success: true, key: res.key, id: res.id });
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "createRemoteLink",
  "Attach an external URL (e.g. GitHub PR) to a Jira issue",
  {
    issueIdOrKey: z.string().describe("Issue key (e.g. PROJ-123)"),
    url: z.string().describe("URL to link"),
    title: z.string().describe("Link display text"),
  },
  async ({ issueIdOrKey, url, title }) => {
    try {
      const res = await jira(
        "POST",
        `/rest/api/3/issue/${issueIdOrKey}/remotelink`,
        { object: { url, title } }
      );
      return ok({ success: true, key: issueIdOrKey, id: res?.id });
    } catch (e) {
      return err(e.message);
    }
  }
);

server.tool(
  "addAttachmentToJiraIssue",
  "Upload a file (screenshot, log, etc.) as an attachment to a Jira issue",
  {
    issueIdOrKey: z.string().describe("Issue key (e.g. PROJ-123)"),
    filePath: z.string().describe("Absolute path to the file to upload"),
  },
  async ({ issueIdOrKey, filePath }) => {
    try {
      if (DRY_RUN) {
        console.error(
          `[dry-run] POST /rest/api/3/issue/${issueIdOrKey}/attachments file=${filePath}`
        );
        return ok({ _dryRun: true });
      }

      const fileData = await readFile(filePath);
      const fileName = basename(filePath);
      const blob = new Blob([fileData]);

      const form = new FormData();
      form.append("file", blob, fileName);

      const res = await fetch(
        `${BASE_URL}/rest/api/3/issue/${issueIdOrKey}/attachments`,
        {
          method: "POST",
          headers: {
            Authorization: `Basic ${AUTH}`,
            "X-Atlassian-Token": "no-check",
          },
          body: form,
        }
      );

      const text = await res.text();
      if (!res.ok) throw new Error(`Jira ${res.status}: ${text}`);
      const data = text ? JSON.parse(text) : null;
      return ok({
        success: true,
        key: issueIdOrKey,
        attachments: data?.map((a) => ({
          id: a.id,
          filename: a.filename,
          content: a.content,
        })),
      });
    } catch (e) {
      return err(e.message);
    }
  }
);

// ── Agent-Action Tools (scoped by RALPH_AGENT_KEY) ──────────────────────────

// ── Implementer ─────────────────────────────────────────────────────────────

if (AGENT_KEY === "implementer") {
  server.tool(
    "ralph_implementer_create_pr",
    "Create a draft PR for the task. ALWAYS creates as draft. Auto-detects base branch from Jira blocker links. Idempotent — returns existing PR if one exists.",
    {
      taskKey: z.string().describe("Jira issue key (e.g. PRODUCT-789)"),
    },
    async ({ taskKey }) => {
      try {
        const branch = `ralph/${taskKey}`;

        // Idempotent: check if PR already exists
        try {
          const existing = await ghJson(
            "pr",
            "view",
            branch,
            "--json",
            "number,url,isDraft,baseRefName"
          );
          if (existing) {
            return ok({
              action: "existing",
              number: existing.number,
              url: existing.url,
              base: existing.baseRefName,
              isDraft: existing.isDraft,
            });
          }
        } catch {
          // No existing PR — continue to create
        }

        // Fetch summary + blocker keys from Jira
        const issue = await jira(
          "GET",
          `/rest/api/3/issue/${taskKey}?fields=summary,issuelinks`
        );
        const summary = issue.fields?.summary || taskKey;
        const blockerKeys = (issue.fields?.issuelinks || [])
          .filter(
            (l) => l.type?.inward === "is blocked by" && l.inwardIssue?.key
          )
          .map((l) => l.inwardIssue.key);

        // Determine base branch: first active blocker branch, else default
        let baseBranch = await getDefaultBranch();
        for (const bk of blockerKeys) {
          if (await branchExists(`ralph/${bk}`)) {
            baseBranch = `ralph/${bk}`;
            break;
          }
        }

        // Push current branch
        await gh("git", "push", "-u", "origin", branch).catch(() =>
          // gh doesn't have git push — use execFile directly
          execFileAsync("git", ["push", "-u", "origin", branch], {
            timeout: 60_000,
          })
        );

        // Create draft PR (ALWAYS draft)
        const pr = await ghJson(
          "pr",
          "create",
          "--draft",
          "--base",
          baseBranch,
          "--head",
          branch,
          "--title",
          `${taskKey}: ${summary}`,
          "--body",
          `Implements ${taskKey}`,
          "--json",
          "number,url"
        );

        return ok({
          action: "created",
          number: pr?.number,
          url: pr?.url,
          base: baseBranch,
          isDraft: true,
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );
}

// ── Reviewer ────────────────────────────────────────────────────────────────

if (AGENT_KEY === "reviewer") {
  server.tool(
    "ralph_reviewer_approve",
    "Approve a task: undrafts the PR, approves it, and adds ready-to-merge label in Jira. Removes code-approved label if present.",
    {
      taskKey: z.string().describe("Jira issue key (e.g. PRODUCT-789)"),
    },
    async ({ taskKey }) => {
      try {
        const branch = `ralph/${taskKey}`;
        let prCreated = false;

        // Check if PR exists
        let pr;
        try {
          pr = await ghJson(
            "pr",
            "view",
            branch,
            "--json",
            "number,isDraft"
          );
        } catch {
          // No PR — create one (fallback for when implementer didn't create it)
          const issue = await jira(
            "GET",
            `/rest/api/3/issue/${taskKey}?fields=summary,issuelinks`
          );
          const summary = issue.fields?.summary || taskKey;
          const blockerKeys = (issue.fields?.issuelinks || [])
            .filter(
              (l) => l.type?.inward === "is blocked by" && l.inwardIssue?.key
            )
            .map((l) => l.inwardIssue.key);

          let baseBranch = await getDefaultBranch();
          for (const bk of blockerKeys) {
            if (await branchExists(`ralph/${bk}`)) {
              baseBranch = `ralph/${bk}`;
              break;
            }
          }

          pr = await ghJson(
            "pr",
            "create",
            "--base",
            baseBranch,
            "--head",
            branch,
            "--title",
            `${taskKey}: ${summary}`,
            "--body",
            `Implements ${taskKey}`,
            "--json",
            "number,isDraft"
          );
          prCreated = true;
        }

        // Undraft if needed
        if (pr.isDraft) {
          await gh("pr", "ready", branch);
        }

        // Approve
        await gh("pr", "review", branch, "--approve");

        // Jira: remove code-approved, add ready-to-merge
        await jiraRemoveLabel(taskKey, "code-approved");
        await jiraAddLabel(taskKey, "ready-to-merge");

        return ok({
          action: "approved",
          number: pr.number,
          prCreated,
          labels: { added: "ready-to-merge", removed: "code-approved" },
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );

  server.tool(
    "ralph_reviewer_reject",
    "Reject a task: adds a comment to Jira explaining what failed, transitions to In Progress. Optionally adds ralph-failed label for build errors.",
    {
      taskKey: z.string().describe("Jira issue key (e.g. PRODUCT-789)"),
      reason: z.string().describe("Explanation of what failed"),
      isBuildError: z
        .boolean()
        .optional()
        .default(false)
        .describe("Set true to add ralph-failed label"),
    },
    async ({ taskKey, reason, isBuildError }) => {
      try {
        // Add comment
        await jira("POST", `/rest/api/3/issue/${taskKey}/comment`, {
          body: markdownToAdf(
            `RALPH_REVIEWER: **Rejected** — ${reason}`
          ),
        });

        // Transition to In Progress
        await jiraTransitionTo(taskKey, "In Progress");

        // Optionally add ralph-failed label
        if (isBuildError) {
          await jiraAddLabel(taskKey, "ralph-failed");
        }

        return ok({
          action: "rejected",
          key: taskKey,
          transitionedTo: "In Progress",
          labelAdded: isBuildError ? "ralph-failed" : null,
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );

  server.tool(
    "ralph_reviewer_needs_tests",
    "Route task to tester: adds comment with testing guidance, adds needs-tests label, transitions to To Do.",
    {
      taskKey: z.string().describe("Jira issue key (e.g. PRODUCT-789)"),
      guidance: z
        .string()
        .describe(
          "Specific testing guidance: which criteria lack evidence, what constitutes acceptable evidence, edge cases to cover"
        ),
    },
    async ({ taskKey, guidance }) => {
      try {
        // Add comment with testing guidance
        await jira("POST", `/rest/api/3/issue/${taskKey}/comment`, {
          body: markdownToAdf(
            `RALPH_REVIEWER: **Needs testing**\n\n${guidance}`
          ),
        });

        // Add needs-tests label
        await jiraAddLabel(taskKey, "needs-tests");

        // Transition to To Do
        await jiraTransitionTo(taskKey, "To Do");

        return ok({
          action: "needs_tests",
          key: taskKey,
          transitionedTo: "To Do",
          labelAdded: "needs-tests",
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );
}

// ── Fixer ───────────────────────────────────────────────────────────────────

if (AGENT_KEY === "fixer") {
  server.tool(
    "ralph_fixer_get_feedback",
    "Get all unresolved review feedback for a PR: inline comments, review threads, and top-level reviews. Pre-filtered to unresolved only.",
    {
      prNumber: z.number().describe("Pull request number"),
    },
    async ({ prNumber }) => {
      try {
        const repo = await getRepo();

        // Fetch review threads via GraphQL (includes resolution status)
        const threadsRaw = await gh(
          "api",
          "graphql",
          "-f",
          `query={
            repository(owner: "${repo.owner}", name: "${repo.name}") {
              pullRequest(number: ${prNumber}) {
                reviewThreads(first: 50) {
                  nodes {
                    id
                    isResolved
                    line
                    path
                    comments(first: 10) {
                      nodes {
                        id
                        databaseId
                        body
                        author { login }
                      }
                    }
                  }
                }
              }
            }
          }`,
          "--jq",
          ".data.repository.pullRequest.reviewThreads.nodes"
        );
        const allThreads = threadsRaw ? JSON.parse(threadsRaw) : [];
        const unresolvedThreads = allThreads.filter((t) => !t.isResolved);

        // Fetch top-level reviews
        const reviews = await ghJson(
          "api",
          `repos/${repo.owner}/${repo.name}/pulls/${prNumber}/reviews`,
          "--jq",
          `[.[] | {id, state, body, author: .user.login}]`
        );

        return ok({
          threads: unresolvedThreads,
          reviews: reviews || [],
          summary: {
            unresolvedThreads: unresolvedThreads.length,
            totalThreads: allThreads.length,
            reviewCount: (reviews || []).length,
          },
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );

  server.tool(
    "ralph_fixer_reply_and_resolve",
    "Reply to a review comment and resolve the thread in one operation.",
    {
      prNumber: z.number().describe("Pull request number"),
      commentId: z.number().describe("Database ID of the comment to reply to"),
      threadId: z
        .string()
        .describe("GraphQL node ID of the thread to resolve"),
      body: z
        .string()
        .describe("Reply text explaining what was changed"),
    },
    async ({ prNumber, commentId, threadId, body }) => {
      try {
        const repo = await getRepo();

        // Reply to comment
        await gh(
          "api",
          `repos/${repo.owner}/${repo.name}/pulls/${prNumber}/comments/${commentId}/replies`,
          "-f",
          `body=${body}`
        );

        // Resolve thread
        await gh(
          "api",
          "graphql",
          "-f",
          `query=mutation {
            resolveReviewThread(input: {threadId: "${threadId}"}) {
              thread { isResolved }
            }
          }`
        );

        return ok({ replied: true, resolved: true });
      } catch (e) {
        return err(e.message);
      }
    }
  );

  server.tool(
    "ralph_fixer_dismiss_reviews",
    "Dismiss all CHANGES_REQUESTED reviews on a PR to clear the review gate.",
    {
      prNumber: z.number().describe("Pull request number"),
    },
    async ({ prNumber }) => {
      try {
        const repo = await getRepo();

        // Get CHANGES_REQUESTED reviews
        const reviewIds = await ghJson(
          "api",
          `repos/${repo.owner}/${repo.name}/pulls/${prNumber}/reviews`,
          "--jq",
          `[.[] | select(.state == "CHANGES_REQUESTED") | .id]`
        );

        const dismissed = [];
        for (const rid of reviewIds || []) {
          try {
            await gh(
              "api",
              "-X",
              "PUT",
              `repos/${repo.owner}/${repo.name}/pulls/${prNumber}/reviews/${rid}/dismissals`,
              "-f",
              "message=All feedback addressed"
            );
            dismissed.push(rid);
          } catch (e) {
            console.error(`Failed to dismiss review ${rid}: ${e.message}`);
          }
        }

        return ok({ dismissed, total: (reviewIds || []).length });
      } catch (e) {
        return err(e.message);
      }
    }
  );
}

// ── Merger ──────────────────────────────────────────────────────────────────

if (AGENT_KEY === "merger") {
  server.tool(
    "ralph_merger_verify",
    "Verify all merge conditions for a PR. Returns a clear yes/no with details.",
    {
      prNumber: z.number().describe("Pull request number"),
    },
    async ({ prNumber }) => {
      try {
        const pr = await ghJson(
          "pr",
          "view",
          String(prNumber),
          "--json",
          "mergeable,reviewDecision,statusCheckRollup,headRefName,baseRefName,isDraft"
        );

        const unresolvedCount = await ghUnresolvedThreadCount(prNumber);

        const mergeable = pr.mergeable === "MERGEABLE";
        const approved = pr.reviewDecision === "APPROVED";
        const threadsResolved = unresolvedCount === 0;
        const isDraft = pr.isDraft;

        // Check CI: all checks must be completed and successful
        const checks = pr.statusCheckRollup || [];
        const ciGreen =
          checks.length > 0 &&
          checks.every(
            (c) =>
              (c.status === "COMPLETED" &&
                (c.conclusion === "SUCCESS" || c.conclusion === "NEUTRAL" || c.conclusion === "SKIPPED")) ||
              c.state === "SUCCESS" ||
              c.state === "NEUTRAL"
          );
        const pendingChecks = checks.filter(
          (c) =>
            c.status === "IN_PROGRESS" ||
            c.status === "QUEUED" ||
            c.status === "PENDING" ||
            c.state === "PENDING"
        );

        const blockers = [];
        if (isDraft) blockers.push("PR is still a draft");
        if (!mergeable) blockers.push("PR has merge conflicts");
        if (!approved) blockers.push(`Review decision: ${pr.reviewDecision || "none"}`);
        if (!threadsResolved) {
          blockers.push(`${unresolvedCount} unresolved review thread(s)`);
        }
        if (!ciGreen) {
          if (pendingChecks.length > 0) {
            blockers.push(
              `${pendingChecks.length} check(s) still running`
            );
          } else {
            const failed = checks.filter(
              (c) => c.conclusion === "FAILURE" || c.state === "FAILURE"
            );
            blockers.push(
              `${failed.length} failed CI check(s)`
            );
          }
        }

        return ok({
          canMerge: blockers.length === 0,
          mergeable,
          ciGreen,
          approved,
          threadsResolved,
          isDraft,
          blockers,
          headRefName: pr.headRefName,
          baseRefName: pr.baseRefName,
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );

  server.tool(
    "ralph_merger_merge",
    "Merge a PR: verifies conditions, squash-merges, deletes branch, retargets child PRs, transitions Jira to Done, and rolls up parent if all subtasks are done. ALWAYS squash merge.",
    {
      prNumber: z.number().describe("Pull request number"),
    },
    async ({ prNumber }) => {
      try {
        // Verify conditions first
        const pr = await ghJson(
          "pr",
          "view",
          String(prNumber),
          "--json",
          "mergeable,reviewDecision,statusCheckRollup,headRefName,baseRefName,isDraft"
        );

        if (pr.isDraft) throw new Error("Cannot merge: PR is still a draft");
        if (pr.mergeable !== "MERGEABLE")
          throw new Error("Cannot merge: PR has conflicts");
        if (pr.reviewDecision !== "APPROVED")
          throw new Error(
            `Cannot merge: review decision is ${pr.reviewDecision || "none"}`
          );
        const unresolvedCount = await ghUnresolvedThreadCount(prNumber);
        if (unresolvedCount > 0)
          throw new Error(
            `Cannot merge: ${unresolvedCount} unresolved thread(s)`
          );

        // Squash merge + delete branch (ALWAYS)
        await gh(
          "pr",
          "merge",
          String(prNumber),
          "--squash",
          "--delete-branch"
        );

        // Retarget child PRs
        const defaultBranch = await getDefaultBranch();
        let retargeted = [];
        try {
          const children = await ghJson(
            "pr",
            "list",
            "--base",
            pr.headRefName,
            "--json",
            "number"
          );
          for (const child of children || []) {
            await gh(
              "pr",
              "edit",
              String(child.number),
              "--base",
              defaultBranch
            );
            retargeted.push(child.number);
          }
        } catch {
          // No children or error — not fatal
        }

        // Extract task key from branch (strip ralph/ prefix)
        const taskKey = pr.headRefName.replace(/^ralph\//, "");
        let jiraResult = { transitioned: false };

        // Transition Jira to Done
        try {
          await jiraTransitionTo(taskKey, "Done");
          await jira("POST", `/rest/api/3/issue/${taskKey}/comment`, {
            body: markdownToAdf(
              `RALPH_MERGER: Merged PR #${prNumber} into ${pr.baseRefName}.`
            ),
          });
          jiraResult.transitioned = true;

          // Parent rollup: if all subtasks Done, close parent
          const issue = await jira(
            "GET",
            `/rest/api/3/issue/${taskKey}?fields=parent`
          );
          if (issue.fields?.parent?.key) {
            const parentKey = issue.fields.parent.key;
            const parent = await jira(
              "GET",
              `/rest/api/3/issue/${parentKey}?fields=subtasks`
            );
            const subtasks = parent.fields?.subtasks || [];
            const allDone = subtasks.every(
              (s) => s.fields?.status?.statusCategory?.key === "done"
            );
            if (allDone && subtasks.length > 0) {
              try {
                await jiraTransitionTo(parentKey, "Done");
                await jira(
                  "POST",
                  `/rest/api/3/issue/${parentKey}/comment`,
                  {
                    body: markdownToAdf(
                      `RALPH_MERGER: All subtasks complete. Closing parent.`
                    ),
                  }
                );
                jiraResult.parentClosed = parentKey;
              } catch {
                // Parent transition failed — not fatal
              }
            }
          }
        } catch (e) {
          jiraResult.error = e.message;
        }

        return ok({
          action: "merged",
          number: prNumber,
          squash: true,
          branchDeleted: pr.headRefName,
          retargetedChildren: retargeted,
          jira: jiraResult,
        });
      } catch (e) {
        return err(e.message);
      }
    }
  );
}

// ── Start ───────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
