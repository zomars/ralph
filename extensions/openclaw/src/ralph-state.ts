export interface AgentInstance {
  agent: string;
  instance: number;
  pid: number;
  alive: boolean;
}

export interface RalphState {
  snapshot(agents: string[]): AgentInstance[];
  fullStatus(projectDir: string): Promise<string>;
}
