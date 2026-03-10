import { spawn } from "child_process";
import { existsSync, readFileSync, readdirSync } from "fs";
import type { RalphControl } from "../ralph-control.js";

export class ShellRalphControl implements RalphControl {
  async start(
    agent: string,
    projectDir: string,
    mode: "--afk" | "--once",
  ): Promise<number | null> {
    const child = spawn("ralph", [agent, mode], {
      cwd: projectDir,
      detached: true,
      stdio: "ignore",
    });
    child.unref();
    return child.pid ?? null;
  }

  async stop(agent: string, instance?: number): Promise<boolean> {
    const baseDir = `/tmp/ralph-${agent}`;
    if (!existsSync(baseDir)) return false;

    const slots =
      instance !== undefined
        ? [String(instance)]
        : readdirSync(baseDir).filter((e: string) => /^\d+$/.test(e));

    let killed = false;
    for (const slot of slots) {
      const pidFile = `${baseDir}/${slot}/pid`;
      if (!existsSync(pidFile)) continue;

      try {
        const pid = parseInt(readFileSync(pidFile, "utf-8").trim(), 10);
        process.kill(pid, "SIGTERM");
        killed = true;
      } catch {
        // Already dead or permission error
      }
    }
    return killed;
  }
}
