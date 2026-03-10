import { z } from "zod";

export const ralphConfigSchema = z.object({
  enabled: z.boolean().default(true),
  projectDir: z.string(),
  chatId: z.string(),
  threadId: z.number().optional(),
  accountId: z.string().optional(),
  agents: z
    .array(z.string())
    .default(["planner", "implementer", "reviewer", "tester", "fixer"]),
  notifications: z
    .object({
      onComplete: z.boolean().default(true),
      onAbort: z.boolean().default(true),
      onStart: z.boolean().default(true),
      onStop: z.boolean().default(true),
    })
    .default({}),
  pollIntervalMs: z.number().default(5000),
});

export type RalphConfig = z.infer<typeof ralphConfigSchema>;
