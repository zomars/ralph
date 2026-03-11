import { ralphConfigSchema, type RalphConfig } from "./src/config.js";
import { FilesystemRalphState } from "./src/ralph-state/filesystem-ralph-state.js";
import { JsonlSessionParser } from "./src/session-parser/jsonl-session-parser.js";
import { ShellRalphControl } from "./src/ralph-control/shell-ralph-control.js";
import { TelegramNotifier } from "./src/notifier/telegram-notifier.js";
import { NullNotifier } from "./src/notifier/null-notifier.js";
import { PollMonitor } from "./src/monitor/poll-monitor.js";
import type { Notifier } from "./src/notifier.js";
import type { MonitorEvent } from "./src/monitor.js";
import {
  formatStatus,
  formatIterationComplete,
  formatIterationAbort,
  formatAgentStarted,
  formatAgentStopped,
} from "./src/formatter.js";

export default {
  id: "ralph",
  configSchema: ralphConfigSchema,

  register(api: any) {
    const cfg = ralphConfigSchema.parse(api.pluginConfig ?? {});
    if (!cfg.enabled) return;

    // --- Wire dependencies ---
    const state = new FilesystemRalphState();
    const parser = new JsonlSessionParser();
    const control = new ShellRalphControl();

    const sendFn =
      api.runtime?.channel?.telegram?.sendMessageTelegram;
    const notifier: Notifier = sendFn
      ? new TelegramNotifier(sendFn, cfg.chatId, cfg)
      : new NullNotifier();

    const monitor = new PollMonitor(state, parser, cfg.pollIntervalMs);

    // --- Monitor event handler ---
    function handleMonitorEvent(event: MonitorEvent): void {
      let text: string | null = null;

      switch (event.type) {
        case "iteration_complete":
          if (!cfg.notifications.onComplete) break;
          text = formatIterationComplete(event.agent, event.instance, {
            taskKey: event.taskKey ?? null,
            promise: "COMPLETE",
            iteration: event.iteration ?? 0,
            summaryLines: event.summaryLines ?? [],
          });
          break;
        case "iteration_abort":
          if (!cfg.notifications.onAbort) break;
          text = formatIterationAbort(event.agent, event.instance, {
            taskKey: event.taskKey ?? null,
            promise: "ABORT",
            iteration: event.iteration ?? 0,
            summaryLines: event.summaryLines ?? [],
          });
          break;
        case "agent_started":
          if (!cfg.notifications.onStart) break;
          text = formatAgentStarted(
            event.agent,
            event.instance,
            event.pid ?? 0,
          );
          break;
        case "agent_stopped":
          if (!cfg.notifications.onStop) break;
          text = formatAgentStopped(event.agent, event.instance);
          break;
      }

      if (text) {
        notifier.send(text).catch(() => {});
      }
    }

    // --- /ralph command (Telegram) ---
    api.registerCommand({
      name: "ralph",
      description: "Monitor and control Ralph agents",
      acceptsArgs: true,

      async handler(ctx: any) {
        const args = (ctx.args ?? "").trim().split(/\s+/);
        const sub = args[0] || "status";
        const target = args[1];
        const extra = args[2];

        switch (sub) {
          case "status": {
            const output = await state.fullStatus(cfg.projectDir);
            return { text: formatStatus(output) };
          }

          case "start": {
            if (!target)
              return { text: "Usage: /ralph start <agent>" };
            const pid = await control.start(
              target,
              cfg.projectDir,
              "--afk",
            );
            return {
              text: pid
                ? `▶ Started ${target} (PID ${pid})`
                : `Failed to start ${target}`,
            };
          }

          case "once": {
            if (!target)
              return { text: "Usage: /ralph once <agent>" };
            const pid = await control.start(
              target,
              cfg.projectDir,
              "--once",
            );
            return {
              text: pid
                ? `▶ Started ${target} --once (PID ${pid})`
                : `Failed to start ${target}`,
            };
          }

          case "stop": {
            if (!target)
              return { text: "Usage: /ralph stop <agent> [N]" };
            const instance = extra ? parseInt(extra, 10) : undefined;
            const ok = await control.stop(target, instance);
            return {
              text: ok
                ? `■ Stopped ${target}${instance ? ` #${instance}` : ""}`
                : `No running instance of ${target} found`,
            };
          }

          case "log": {
            if (!target)
              return { text: "Usage: /ralph log <agent> [N]" };
            const inst = extra ? parseInt(extra, 10) : 1;
            const logPath = `/tmp/ralph-${target}/${inst}/session.log`;
            const summary = parser.parseLatestIteration(logPath);
            if (!summary)
              return { text: `No session log for ${target} #${inst}` };
            const prom = summary.promise ?? "in progress";
            const lines = summary.summaryLines.join("\n");
            return {
              text: `**${target.toUpperCase()} #${inst}** — ${prom}\nTask: ${summary.taskKey ?? "?"} | Iteration: ${summary.iteration}\n${lines}`,
            };
          }

          default:
            return {
              text: "Commands: status, start, stop, once, log",
            };
        }
      },
    });

    // --- Background monitor service ---
    api.registerService({
      id: "ralph-monitor",
      start() {
        monitor.start(cfg.agents, handleMonitorEvent);
      },
      stop() {
        monitor.stop();
      },
    });

    // --- CLI: `openclaw ralph ...` ---
    api.registerCli(
      ({ program }: any) => {
        const cmd = program
          .command("ralph")
          .description("Ralph agent bridge");

        cmd
          .command("status")
          .description("Show agent status")
          .action(async () => {
            const output = await state.fullStatus(cfg.projectDir);
            console.log(output);
          });

        cmd
          .command("start <agent>")
          .description("Start agent in --afk mode")
          .action(async (agent: string) => {
            const pid = await control.start(
              agent,
              cfg.projectDir,
              "--afk",
            );
            console.log(
              pid ? `Started ${agent} (PID ${pid})` : `Failed to start ${agent}`,
            );
          });

        cmd
          .command("once <agent>")
          .description("Start agent in --once mode")
          .action(async (agent: string) => {
            const pid = await control.start(
              agent,
              cfg.projectDir,
              "--once",
            );
            console.log(
              pid
                ? `Started ${agent} --once (PID ${pid})`
                : `Failed to start ${agent}`,
            );
          });

        cmd
          .command("stop <agent> [instance]")
          .description("Stop agent instance(s)")
          .action(async (agent: string, instance?: string) => {
            const inst = instance ? parseInt(instance, 10) : undefined;
            const ok = await control.stop(agent, inst);
            console.log(
              ok
                ? `Stopped ${agent}${inst ? ` #${inst}` : ""}`
                : `No running instance found`,
            );
          });

        cmd
          .command("log <agent> [instance]")
          .description("Show last iteration summary")
          .action(async (agent: string, instance?: string) => {
            const inst = instance ? parseInt(instance, 10) : 1;
            const logPath = `/tmp/ralph-${agent}/${inst}/session.log`;
            const summary = parser.parseLatestIteration(logPath);
            if (!summary) {
              console.log(`No session log for ${agent} #${inst}`);
              return;
            }
            console.log(
              `${agent.toUpperCase()} #${inst} — ${summary.promise ?? "in progress"}`,
            );
            console.log(
              `Task: ${summary.taskKey ?? "?"} | Iteration: ${summary.iteration}`,
            );
            for (const line of summary.summaryLines) {
              console.log(line);
            }
          });
      },
      { commands: ["ralph"] },
    );
  },
};
