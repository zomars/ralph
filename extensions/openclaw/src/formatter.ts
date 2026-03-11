import type { AgentInstance } from "./ralph-state.js";
import type { IterationSummary } from "./session-parser.js";

export function formatStatus(statusOutput: string): string {
  return "```\nRALPH STATUS\n" + statusOutput + "\n```";
}

export function formatIterationComplete(
  agent: string,
  instance: number,
  summary: IterationSummary,
): string {
  const header = `**✓ RALPH\\_${agent.toUpperCase()} #${instance} — COMPLETE**`;
  const meta = `Task: ${summary.taskKey ?? "unknown"} | Iteration: ${summary.iteration}`;
  const body = summary.summaryLines.join("\n");
  return [header, meta, body].filter(Boolean).join("\n");
}

export function formatIterationAbort(
  agent: string,
  instance: number,
  summary: IterationSummary,
): string {
  const header = `**✗ RALPH\\_${agent.toUpperCase()} #${instance} — ABORT**`;
  const meta = `Task: ${summary.taskKey ?? "unknown"} | Iteration: ${summary.iteration}`;
  const body = summary.summaryLines.join("\n");
  return [header, meta, body].filter(Boolean).join("\n");
}

export function formatAgentStarted(
  agent: string,
  instance: number,
  pid: number,
): string {
  return `▶ RALPH\\_${agent.toUpperCase()} #${instance} started (PID ${pid})`;
}

export function formatAgentStopped(agent: string, instance: number): string {
  return `■ RALPH\\_${agent.toUpperCase()} #${instance} stopped`;
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
  return "```\n" + lines.join("\n") + "\n```";
}
