import { existsSync, readFileSync } from "fs";
import type { IterationSummary, SessionParser } from "../session-parser.js";

export class JsonlSessionParser implements SessionParser {
  parseLatestIteration(sessionLogPath: string): IterationSummary | null {
    if (!existsSync(sessionLogPath)) return null;

    let raw: string;
    try {
      raw = readFileSync(sessionLogPath, "utf-8");
    } catch {
      return null;
    }

    const lines = raw.split("\n").filter((l) => l.startsWith("{"));
    if (lines.length === 0) return null;

    // Find last _ralph_marker
    let markerIdx = -1;
    let iteration = 0;
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const obj = JSON.parse(lines[i]);
        if (obj.type === "_ralph_marker") {
          markerIdx = i;
          iteration = obj.iteration ?? 0;
          break;
        }
      } catch {
        // skip malformed lines
      }
    }

    // Extract text blocks and promise from lines after marker
    const startIdx = markerIdx === -1 ? 0 : markerIdx + 1;
    const textBlocks: string[] = [];
    let promise: "COMPLETE" | "ABORT" | null = null;
    let taskKey: string | null = null;

    for (let i = startIdx; i < lines.length; i++) {
      try {
        const obj = JSON.parse(lines[i]);

        // Extract text content from assistant messages
        if (obj.type === "assistant" && obj.message?.content) {
          for (const block of obj.message.content) {
            if (block.type === "text" && block.text) {
              textBlocks.push(block.text);
            }
          }
        }

        // Check result for promise
        if (obj.type === "result" && typeof obj.result === "string") {
          const completeMatch = obj.result.match(
            /<promise>COMPLETE<\/promise>/,
          );
          const abortMatch = obj.result.match(/<promise>ABORT<\/promise>/);
          if (completeMatch) promise = "COMPLETE";
          if (abortMatch) promise = "ABORT";
        }
      } catch {
        // skip malformed
      }
    }

    // Extract task key from text (patterns like PROJ-123, PROD-42, etc.)
    for (const text of textBlocks) {
      const match = text.match(/\b([A-Z][A-Z0-9]+-\d+)\b/);
      if (match) {
        taskKey = match[1];
        break;
      }
    }

    // Last 3 text blocks as summary
    const summaryLines = textBlocks.slice(-3).map((t) => {
      const trimmed = t.trim();
      return trimmed.length > 120 ? trimmed.slice(0, 117) + "..." : trimmed;
    });

    return { taskKey, promise, iteration, summaryLines };
  }
}
