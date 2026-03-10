export interface RalphControl {
  start(
    agent: string,
    projectDir: string,
    mode: "--afk" | "--once",
  ): Promise<number | null>;
  stop(agent: string, instance?: number): Promise<boolean>;
}
