#!/usr/bin/env node
// Single source of truth for ralph's PR approval gate.
//
// Rule:
//   - If branch protection sets reviewDecision (APPROVED / REVIEW_REQUIRED /
//     CHANGES_REQUESTED), defer to it strictly — require APPROVED.
//   - Otherwise, accept any APPROVED review from a write-access user
//     (OWNER/MEMBER/COLLABORATOR) or a Bot/App, provided no CHANGES_REQUESTED
//     is outstanding in latestReviews.
//
// Input PR shape (subset):
//   {
//     reviewDecision: "APPROVED" | "REVIEW_REQUIRED" | "CHANGES_REQUESTED" | null,
//     latestReviews: { nodes: [...] } | [...]   // either GraphQL or array shape accepted
//   }
//   Each review: { state, authorAssociation, author: { __typename | is_bot } }
//
// Library use:  import { checkApproval } from "./pr-approval.mjs"
// CLI use:      cat prs.json | node lib/pr-approval.mjs --filter
//   stdin: JSON array of PR objects (each with reviewDecision + latestReviews)
//   stdout: same array filtered to approved-only

const WRITE_ACCESS = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);

function reviewsOf(pr) {
  const lr = pr.latestReviews;
  if (!lr) return [];
  if (Array.isArray(lr)) return lr;
  return lr.nodes || [];
}

function isBotAuthor(author) {
  if (!author) return false;
  return author.__typename === "Bot" || author.is_bot === true;
}

export function checkApproval(pr) {
  if (pr.reviewDecision) {
    const approved = pr.reviewDecision === "APPROVED";
    return {
      approved,
      reason: approved ? "approved" : `Review decision: ${pr.reviewDecision}`,
    };
  }
  const reviews = reviewsOf(pr);
  if (reviews.some((r) => r.state === "CHANGES_REQUESTED")) {
    return { approved: false, reason: "Changes requested in latest review" };
  }
  const qualifying = reviews.some(
    (r) =>
      r.state === "APPROVED" &&
      (WRITE_ACCESS.has(r.authorAssociation) || isBotAuthor(r.author))
  );
  return {
    approved: qualifying,
    reason: qualifying
      ? "approved"
      : "No qualifying approval (need write-access user or App)",
  };
}

// CLI: --filter reads a JSON array from stdin and emits the approved subset
if (import.meta.url === `file://${process.argv[1]}`) {
  const mode = process.argv[2] || "--filter";
  if (mode !== "--filter") {
    console.error(`Usage: ${process.argv[1]} --filter  # reads JSON array from stdin`);
    process.exit(2);
  }
  let buf = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (buf += c));
  process.stdin.on("end", () => {
    let prs;
    try {
      prs = JSON.parse(buf || "[]");
    } catch (e) {
      console.error(`pr-approval: invalid JSON on stdin: ${e.message}`);
      process.exit(1);
    }
    if (!Array.isArray(prs)) {
      console.error("pr-approval: stdin must be a JSON array");
      process.exit(1);
    }
    const filtered = prs.filter((pr) => checkApproval(pr).approved);
    process.stdout.write(JSON.stringify(filtered));
  });
}
