import type { AgentInstance } from "./ralph-state.js";
import type { IterationSummary } from "./session-parser.js";

export function formatStatus(statusOutput: string): string {
  return `<pre>RALPH STATUS\n${escapeHtml(statusOutput)}</pre>`;
}

export function formatIterationComplete(
  agent: string,
  instance: number,
  summary: IterationSummary,
): string {
  const header = `<b>✓ RALPH_${agent.toUpperCase()} #${instance} — COMPLETE</b>`;
  const meta = `Task: ${summary.taskKey ?? "unknown"} | Iteration: ${summary.iteration}`;
  const body = summary.summaryLines.map((l) => escapeHtml(l)).join("\n");
  return [header, meta, body].filter(Boolean).join("\n");
}

export function formatIterationAbort(
  agent: string,
  instance: number,
  summary: IterationSummary,
): string {
  const header = `<b>✗ RALPH_${agent.toUpperCase()} #${instance} — ABORT</b>`;
  const meta = `Task: ${summary.taskKey ?? "unknown"} | Iteration: ${summary.iteration}`;
  const body = summary.summaryLines.map((l) => escapeHtml(l)).join("\n");
  return [header, meta, body].filter(Boolean).join("\n");
}

export function formatAgentStarted(
  agent: string,
  instance: number,
  pid: number,
): string {
  return `▶ RALPH_${agent.toUpperCase()} #${instance} started (PID ${pid})`;
}

export function formatAgentStopped(agent: string, instance: number): string {
  return `■ RALPH_${agent.toUpperCase()} #${instance} stopped`;
}

export function formatInstanceList(instances: AgentInstance[]): string {
  if (instances.length === 0) return "No running agents.";
  const lines = instances
    .filter((i) => i.alive)
    .map(
      (i) =>
        `  ${i.agent.toUpperCase()} #${i.instance} — PID ${i.pid}`,
    );
  if (lines.length === 0) return "No running agents.";
  return `<pre>${lines.join("\n")}</pre>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
