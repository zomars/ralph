import { existsSync } from "fs";
import type { RalphState } from "../ralph-state.js";
import type { SessionParser, IterationSummary } from "../session-parser.js";
import type { Monitor, MonitorEventHandler } from "../monitor.js";

interface SlotState {
  pid: number;
  alive: boolean;
  iteration: number;
  promise: string | null;
}

export class PollMonitor implements Monitor {
  private timer: ReturnType<typeof setInterval> | null = null;
  private state = new Map<string, SlotState>();

  constructor(
    private readonly ralphState: RalphState,
    private readonly parser: SessionParser,
    private readonly pollIntervalMs: number,
  ) {}

  start(agents: string[], onEvent: MonitorEventHandler): void {
    if (this.timer) return;

    this.timer = setInterval(() => {
      this.poll(agents, onEvent);
    }, this.pollIntervalMs);

    // Initial poll
    this.poll(agents, onEvent);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private poll(agents: string[], onEvent: MonitorEventHandler): void {
    const instances = this.ralphState.snapshot(agents);
    const currentKeys = new Set<string>();

    for (const inst of instances) {
      const key = `${inst.agent}-${inst.instance}`;
      currentKeys.add(key);
      const prev = this.state.get(key);

      if (!prev && inst.alive) {
        // New agent appeared
        this.state.set(key, {
          pid: inst.pid,
          alive: true,
          iteration: 0,
          promise: null,
        });
        onEvent({
          type: "agent_started",
          agent: inst.agent,
          instance: inst.instance,
          pid: inst.pid,
        });
      } else if (prev && prev.alive && !inst.alive) {
        // Agent died
        this.state.set(key, { ...prev, alive: false });
        onEvent({
          type: "agent_stopped",
          agent: inst.agent,
          instance: inst.instance,
          pid: prev.pid,
        });
      } else if (!prev && !inst.alive) {
        // Stale slot, just track it
        this.state.set(key, {
          pid: inst.pid,
          alive: false,
          iteration: 0,
          promise: null,
        });
        continue;
      }

      // Check session log for new iterations
      if (inst.alive) {
        const logPath = `/tmp/ralph-${inst.agent}/${inst.instance}/session.log`;
        if (!existsSync(logPath)) continue;

        const summary = this.parser.parseLatestIteration(logPath);
        if (!summary) continue;

        const current = this.state.get(key)!;
        if (
          summary.promise &&
          (summary.iteration !== current.iteration ||
            summary.promise !== current.promise)
        ) {
          this.state.set(key, {
            ...current,
            iteration: summary.iteration,
            promise: summary.promise,
          });

          onEvent({
            type:
              summary.promise === "COMPLETE"
                ? "iteration_complete"
                : "iteration_abort",
            agent: inst.agent,
            instance: inst.instance,
            pid: inst.pid,
            iteration: summary.iteration,
            taskKey: summary.taskKey,
            summaryLines: summary.summaryLines,
          });
        }
      }
    }

    // Check for disappeared slots
    for (const [key, prev] of this.state) {
      if (!currentKeys.has(key) && prev.alive) {
        const [agent, instanceStr] = key.split("-");
        this.state.set(key, { ...prev, alive: false });
        onEvent({
          type: "agent_stopped",
          agent,
          instance: parseInt(instanceStr, 10),
          pid: prev.pid,
        });
      }
    }
  }
}
