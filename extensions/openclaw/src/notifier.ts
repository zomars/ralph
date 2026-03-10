export interface Notifier {
  send(text: string): Promise<void>;
}
