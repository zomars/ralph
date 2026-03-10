import { existsSync, readdirSync, readFileSync } from "fs";
import { execFileSync } from "child_process";
import type { AgentInstance, RalphState } from "../ralph-state.js";

export class FilesystemRalphState implements RalphState {
  snapshot(agents: string[]): AgentInstance[] {
    const instances: AgentInstance[] = [];

    for (const agent of agents) {
      const baseDir = `/tmp/ralph-${agent}`;
      if (!existsSync(baseDir)) continue;

      let entries: string[];
      try {
        entries = readdirSync(baseDir);
      } catch {
        continue;
      }

      for (const entry of entries) {
        const num = parseInt(entry, 10);
        if (isNaN(num)) continue;

        const pidFile = `${baseDir}/${entry}/pid`;
        if (!existsSync(pidFile)) continue;

        let pid: number;
        try {
          pid = parseInt(readFileSync(pidFile, "utf-8").trim(), 10);
        } catch {
          continue;
        }

        let alive = false;
        try {
          process.kill(pid, 0);
          alive = true;
        } catch {
          // PID not running
        }

        instances.push({ agent, instance: num, pid, alive });
      }
    }

    return instances;
  }

  async fullStatus(projectDir: string): Promise<string> {
    try {
      const output = execFileSync("ralph", ["status"], {
        cwd: projectDir,
        encoding: "utf-8",
        timeout: 10_000,
      });
      return output.trim();
    } catch (err: any) {
      return `Error running ralph status: ${err.message}`;
    }
  }
}
