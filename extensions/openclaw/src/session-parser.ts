export interface IterationSummary {
  taskKey: string | null;
  promise: "COMPLETE" | "ABORT" | null;
  iteration: number;
  summaryLines: string[];
}

export interface SessionParser {
  parseLatestIteration(sessionLogPath: string): IterationSummary | null;
}
