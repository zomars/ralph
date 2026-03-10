export type MonitorEventType =
  | "iteration_complete"
  | "iteration_abort"
  | "agent_started"
  | "agent_stopped";

export interface MonitorEvent {
  type: MonitorEventType;
  agent: string;
  instance: number;
  pid?: number;
  iteration?: number;
  taskKey?: string | null;
  summaryLines?: string[];
}

export type MonitorEventHandler = (event: MonitorEvent) => void;

export interface Monitor {
  start(agents: string[], onEvent: MonitorEventHandler): void;
  stop(): void;
}
