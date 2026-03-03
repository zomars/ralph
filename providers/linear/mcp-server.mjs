#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// ── Config ──────────────────────────────────────────────────────────────────

const API_KEY = process.env.LINEAR_API_KEY;
const DRY_RUN = process.argv.includes("--dry-run");

if (!API_KEY) {
  console.error("Missing required env var: LINEAR_API_KEY");
  process.exit(1);
}

// ── GraphQL helper ──────────────────────────────────────────────────────────

async function linear(query, variables = {}) {
  if (DRY_RUN) {
    console.error(`[dry-run] GraphQL`, JSON.stringify({ query, variables }, null, 2));
    return { _dryRun: true };
  }

  const res = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: API_KEY,
    },
    body: JSON.stringify({ query, variables }),
  });

  const json = await res.json();
  if (json.errors?.length) {
    throw new Error(json.errors.map((e) => e.message).join("; "));
  }
  return json.data;
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
  name: "ralph-linear",
  version: "1.0.0",
});

// 1. Search issues
server.tool(
  "searchIssues",
  "Search Linear issues using a filter object. Pass a GraphQL IssueFilter.",
  {
    filter: z
      .record(z.string(), z.any())
      .describe("GraphQL IssueFilter object (e.g. {state: {name: {in: [\"Todo\"]}}})"),
    maxResults: z
      .number()
      .optional()
      .default(10)
      .describe("Max results (default 10, max 50)"),
  },
  async ({ filter, maxResults }) => {
    try {
      const data = await linear(
        `query ($filter: IssueFilter, $first: Int) {
          issues(filter: $filter, first: $first, orderBy: updatedAt) {
            nodes {
              id
              identifier
              title
              state { name }
              priority
              labels { nodes { name } }
              assignee { name email isMe }
              description
              createdAt
              updatedAt
            }
          }
        }`,
        { filter, first: Math.min(maxResults ?? 10, 50) }
      );
      return ok(data.issues);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 2. Get issue
server.tool(
  "getIssue",
  "Get a Linear issue by identifier (e.g. ENG-123)",
  {
    issueId: z.string().describe("Issue identifier (e.g. ENG-123)"),
  },
  async ({ issueId }) => {
    try {
      const data = await linear(
        `query ($id: String!) {
          issue(id: $id) {
            id
            identifier
            title
            description
            state { id name }
            priority
            priorityLabel
            labels { nodes { id name } }
            assignee { id name email isMe }
            relations {
              nodes {
                type
                relatedIssue { identifier title state { name } }
              }
            }
            comments {
              nodes {
                body
                user { name }
                createdAt
              }
            }
            parent { identifier title }
            children { nodes { identifier title state { name } } }
            createdAt
            updatedAt
          }
        }`,
        { id: issueId }
      );
      return ok(data.issue);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 3. Update issue
server.tool(
  "updateIssue",
  "Update a Linear issue. Accepts stateId, labelIds, description (markdown), assigneeId, priority, title.",
  {
    issueId: z.string().describe("Issue identifier (e.g. ENG-123)"),
    input: z
      .record(z.string(), z.any())
      .describe("IssueUpdateInput fields (stateId, labelIds, description, assigneeId, priority, title)"),
  },
  async ({ issueId, input }) => {
    try {
      // Resolve identifier to internal ID first
      const lookup = await linear(
        `query ($id: String!) { issue(id: $id) { id } }`,
        { id: issueId }
      );
      if (!lookup.issue) throw new Error(`Issue not found: ${issueId}`);

      const data = await linear(
        `mutation ($id: String!, $input: IssueUpdateInput!) {
          issueUpdate(id: $id, input: $input) {
            success
            issue { identifier state { name } labels { nodes { name } } }
          }
        }`,
        { id: lookup.issue.id, input }
      );
      return ok(data.issueUpdate);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 4. Add comment
server.tool(
  "addComment",
  "Add a comment to a Linear issue. Body is markdown.",
  {
    issueId: z.string().describe("Issue identifier (e.g. ENG-123)"),
    body: z.string().describe("Comment text in markdown"),
  },
  async ({ issueId, body }) => {
    try {
      const lookup = await linear(
        `query ($id: String!) { issue(id: $id) { id } }`,
        { id: issueId }
      );
      if (!lookup.issue) throw new Error(`Issue not found: ${issueId}`);

      const data = await linear(
        `mutation ($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) {
            success
            comment { id createdAt }
          }
        }`,
        { issueId: lookup.issue.id, body }
      );
      return ok(data.commentCreate);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 5. Get workflow states
server.tool(
  "getWorkflowStates",
  "List available workflow states for a team",
  {
    teamId: z.string().describe("Team key (e.g. ENG) or UUID"),
  },
  async ({ teamId }) => {
    try {
      const data = await linear(
        `query ($teamId: String!) {
          workflowStates(filter: { team: { key: { eq: $teamId } } }) {
            nodes { id name type position }
          }
        }`,
        { teamId }
      );
      return ok(data.workflowStates);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 6. Get team labels
server.tool(
  "getTeamLabels",
  "List labels for a team (agents need IDs to set them)",
  {
    teamId: z.string().describe("Team key (e.g. ENG) or UUID"),
  },
  async ({ teamId }) => {
    try {
      const data = await linear(
        `query ($teamId: String!) {
          issueLabels(filter: { team: { key: { eq: $teamId } } }) {
            nodes { id name color }
          }
        }`,
        { teamId }
      );
      return ok(data.issueLabels);
    } catch (e) {
      return err(e.message);
    }
  }
);

// 7. Create relation
server.tool(
  "createRelation",
  "Create a relation between two Linear issues (e.g. blocks, relates, duplicates)",
  {
    issueId: z.string().describe("Source issue identifier (e.g. ENG-1)"),
    relatedIssueId: z.string().describe("Target issue identifier (e.g. ENG-2)"),
    type: z
      .enum(["blocks", "duplicate", "related"])
      .describe("Relation type: blocks, duplicate, or related"),
  },
  async ({ issueId, relatedIssueId, type }) => {
    try {
      const [src, tgt] = await Promise.all([
        linear(`query ($id: String!) { issue(id: $id) { id } }`, { id: issueId }),
        linear(`query ($id: String!) { issue(id: $id) { id } }`, { id: relatedIssueId }),
      ]);
      if (!src.issue) throw new Error(`Issue not found: ${issueId}`);
      if (!tgt.issue) throw new Error(`Issue not found: ${relatedIssueId}`);

      const data = await linear(
        `mutation ($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
          issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type }) {
            success
            issueRelation { type issue { identifier } relatedIssue { identifier } }
          }
        }`,
        { issueId: src.issue.id, relatedIssueId: tgt.issue.id, type }
      );
      return ok(data.issueRelationCreate);
    } catch (e) {
      return err(e.message);
    }
  }
);

// ── Start ───────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
