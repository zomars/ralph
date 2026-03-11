import type { Notifier } from "../notifier.js";
import type { RalphConfig } from "../config.js";

type SendFn = (
  chatId: string,
  text: string,
  opts?: Record<string, unknown>,
) => Promise<unknown>;

export class TelegramNotifier implements Notifier {
  constructor(
    private readonly sendFn: SendFn,
    private readonly chatId: string,
    private readonly config: Pick<RalphConfig, "threadId" | "accountId">,
  ) {}

  async send(text: string): Promise<void> {
    const opts: Record<string, unknown> = {};
    if (this.config.threadId) {
      opts.messageThreadId = this.config.threadId;
    }
    if (this.config.accountId) {
      opts.accountId = this.config.accountId;
    }
    await this.sendFn(this.chatId, text, opts);
  }
}
