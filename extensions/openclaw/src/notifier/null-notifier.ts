import type { Notifier } from "../notifier.js";

export class NullNotifier implements Notifier {
  async send(_text: string): Promise<void> {
    // No-op
  }
}
