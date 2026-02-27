#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { marked } from "marked";

// ── Config ──────────────────────────────────────────────────────────────────

const BASE_URL = process.env.JIRA_BASE_URL?.replace(/\/$/, "");
const EMAIL = process.env.JIRA_EMAIL;
const TOKEN = process.env.JIRA_API_TOKEN;
const DRY_RUN = process.argv.includes("--dry-run");

if (!BASE_URL || !EMAIL || !TOKEN) {
  console.error(
    "Missing required env vars: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN"
  );
  process.exit(1);
}

const AUTH = Buffer.from(`${EMAIL}:${TOKEN}`).toString("base64");

// ── HTTP helper ─────────────────────────────────────────────────────────────

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

// ── Markdown → ADF ──────────────────────────────────────────────────────────

function markdownToAdf(md) {
  const tokens = marked.lexer(md);
  const content = tokens.flatMap(blockToAdf).filter(Boolean);
  return {
    version: 1,
    type: "doc",
    content: content.length ? content : [{ type: "paragraph", content: [txt("")] }],
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

    case "paragraph":
      return { type: "paragraph", content: inlineToAdf(token.tokens) };

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
        // Tight list — wrap inline content in paragraph
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
        nodes.push(
          ...inlineToAdf(t.tokens, [...marks, { type: "strong" }])
        );
        break;
      case "em":
        nodes.push(...inlineToAdf(t.tokens, [...marks, { type: "em" }]));
        break;
      case "del":
        nodes.push(
          ...inlineToAdf(t.tokens, [...marks, { type: "strike" }])
        );
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
  name: "ralph-jira",
  version: "1.0.0",
});

// 1. Search issues
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
    fields: z
      .array(z.string())
      .optional()
      .describe("Fields to return"),
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

// 2. Get issue
server.tool(
  "getJiraIssue",
  "Get a Jira issue by key or ID",
  {
    issueIdOrKey: z
      .string()
      .describe("Issue key (e.g. PROJ-123) or numeric ID"),
    fields: z
      .array(z.string())
      .optional()
      .describe("Fields to return"),
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

// 3. Edit issue
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

// 4. Add comment
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

// 5. Get transitions
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

// 6. Transition issue
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

// 7. Create issue link
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

// 8. Create remote link
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
      const res = await jira("POST", `/rest/api/3/issue/${issueIdOrKey}/remotelink`, {
        object: { url, title },
      });
      return ok({ success: true, key: issueIdOrKey, id: res?.id });
    } catch (e) {
      return err(e.message);
    }
  }
);

// ── Start ───────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
